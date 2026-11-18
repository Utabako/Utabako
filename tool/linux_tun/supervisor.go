//go:build linux

package main

import (
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/sagernet/netlink"
	"github.com/sagernet/nftables"
	"github.com/sagernet/nftables/userdata"
	"golang.org/x/sys/unix"
)

func main() {
	if err := supervise(); err != nil {
		fmt.Fprintln(os.Stderr, "boxdd:", err)
		var workerExit *exec.ExitError
		if errors.As(err, &workerExit) {
			status := workerExit.Sys().(syscall.WaitStatus)
			if status.Signaled() {
				os.Exit(128 + int(status.Signal()))
			}
			os.Exit(status.ExitStatus())
		}
		os.Exit(1)
	}
}

func supervise() error {
	self, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locate boxdd: %w", err)
	}
	core := filepath.Join(filepath.Dir(self), "boxdd-core")
	args := os.Args[1:]
	if len(args) == 0 || args[0] != "run" {
		return unix.Exec(core, os.Args, os.Environ())
	}
	if disabled, _ := strconv.ParseBool(os.Getenv("DISABLE_NFTABLES")); disabled {
		return errors.New("DISABLE_NFTABLES is incompatible with guarded TUN cleanup")
	}

	signals := make(chan os.Signal, 2)
	signal.Notify(signals, os.Interrupt, unix.SIGTERM)
	defer signal.Stop(signals)

	lock, err := net.ListenUnix("unix", &net.UnixAddr{Name: "@utabako-boxdd-tun-guard", Net: "unix"})
	if errors.Is(err, unix.EADDRINUSE) {
		return errors.New("a guarded boxdd is already running in this network namespace")
	}
	if err != nil {
		return fmt.Errorf("lock the network namespace: %w", err)
	}
	defer lock.Close()

	protocol, err := freeProtocol()
	if err != nil {
		return err
	}
	var nonce [16]byte
	rand.Read(nonce[:])
	tableName := fmt.Sprintf("utabako_tun_%x", nonce)

	worker := exec.Command(core, args...)
	worker.Stdin, worker.Stdout, worker.Stderr = os.Stdin, os.Stdout, os.Stderr
	worker.Env = append(os.Environ(),
		"UTABAKO_TUN_OWNER_PROTOCOL="+strconv.Itoa(int(protocol)),
		"UTABAKO_TUN_OWNER_TABLE="+tableName,
	)
	if err := worker.Start(); err != nil {
		return fmt.Errorf("start boxdd-core: %w", err)
	}

	waited := make(chan error, 1)
	go func() { waited <- worker.Wait() }()
	var workerErrors error
	for {
		select {
		case sig := <-signals:
			if err := worker.Process.Signal(sig); err != nil && !errors.Is(err, os.ErrProcessDone) {
				workerErrors = errors.Join(workerErrors, fmt.Errorf("forward %s to boxdd-core: %w", sig, err))
			}
		case err := <-waited:
			if err != nil {
				workerErrors = errors.Join(workerErrors, fmt.Errorf("boxdd-core: %w", err))
			}
			return errors.Join(workerErrors, cleanupRules(protocol), cleanupRoutes(netlink.RouteProtocol(protocol)), cleanupNFTables(tableName))
		}
	}
}

func freeProtocol() (uint8, error) {
	rules, err := netlink.RuleList(netlink.FAMILY_ALL)
	if err != nil {
		return 0, fmt.Errorf("list policy rule protocols: %w", err)
	}
	// RT_FILTER_TABLE with RT_TABLE_UNSPEC includes routes outside the main table.
	routes, err := netlink.RouteListFiltered(netlink.FAMILY_ALL, &netlink.Route{Table: unix.RT_TABLE_UNSPEC}, netlink.RT_FILTER_TABLE)
	if err != nil {
		return 0, fmt.Errorf("list route protocols: %w", err)
	}
	var used [256]bool
	for _, rule := range rules {
		used[rule.Protocol] = true
	}
	for _, route := range routes {
		used[route.Protocol] = true
	}
	for protocol := uint8(128); protocol <= 254; protocol++ {
		if !used[protocol] {
			return protocol, nil
		}
	}
	return 0, errors.New("no available private routing protocol (128–254)")
}

func cleanupRules(protocol uint8) error {
	rules, err := netlink.RuleList(netlink.FAMILY_ALL)
	if err != nil {
		return fmt.Errorf("list owned policy rules (protocol %d): %w", protocol, err)
	}
	var cleanupErr error
	for _, rule := range rules {
		if rule.Protocol != protocol {
			continue
		}
		// FRA_PROTOCOL is part of the kernel's deletion selector; priority alone is not ownership.
		selector := netlink.NewRule()
		selector.Family, selector.Priority, selector.Protocol = rule.Family, rule.Priority, rule.Protocol
		if err := netlink.RuleDel(selector); err != nil && !errors.Is(err, unix.ENOENT) {
			cleanupErr = errors.Join(cleanupErr, fmt.Errorf("delete policy rule (family %d, priority %d, protocol %d): %w", rule.Family, rule.Priority, protocol, err))
		}
	}
	return cleanupErr
}

func cleanupRoutes(protocol netlink.RouteProtocol) error {
	filter := &netlink.Route{Table: unix.RT_TABLE_UNSPEC, Protocol: protocol}
	routes, err := netlink.RouteListFiltered(netlink.FAMILY_ALL, filter, netlink.RT_FILTER_TABLE|netlink.RT_FILTER_PROTOCOL)
	if err != nil {
		return fmt.Errorf("list owned routes (protocol %d): %w", protocol, err)
	}
	var cleanupErr error
	for _, route := range routes {
		if route.Dst == nil && route.MPLSDst == nil {
			// RouteDel needs a destination to encode a default route without a gateway.
			switch route.Family {
			case netlink.FAMILY_V4:
				route.Dst = &net.IPNet{IP: net.IPv4zero, Mask: net.CIDRMask(0, 32)}
			case netlink.FAMILY_V6:
				route.Dst = &net.IPNet{IP: net.IPv6zero, Mask: net.CIDRMask(0, 128)}
			}
		}
		if err := netlink.RouteDel(&route); err != nil && !errors.Is(err, unix.ENOENT) && !errors.Is(err, unix.ESRCH) {
			cleanupErr = errors.Join(cleanupErr, fmt.Errorf("delete route (table %d, protocol %d) %s: %w", route.Table, protocol, route, err))
		}
	}
	return cleanupErr
}

func cleanupNFTables(tableName string) error {
	var nft nftables.Conn
	var cleanupErr error
	tables, err := nft.ListTablesOfFamily(nftables.TableFamilyINet)
	if err != nil {
		cleanupErr = fmt.Errorf("list inet nftables tables: %w", err)
	}
	for _, table := range tables {
		if table.Name != tableName && table.Name != tableName+"_probe" {
			continue
		}
		nft.DelTable(table)
		if err := nft.Flush(); err != nil && !errors.Is(err, unix.ENOENT) {
			cleanupErr = errors.Join(cleanupErr, fmt.Errorf("delete inet nftables table %s: %w", table.Name, err))
		}
	}

	// List chains instead of a named lookup, which does not preserve ENOENT in this library.
	chains, err := nft.ListChains()
	if err != nil {
		return errors.Join(cleanupErr, fmt.Errorf("list nftables chains: %w", err))
	}
	prefix := "!" + tableName + ": Docker compatibility "
	for _, chain := range chains {
		family := chain.Table.Family
		if chain.Name != "DOCKER-USER" || chain.Table.Name != "filter" || (family != nftables.TableFamilyIPv4 && family != nftables.TableFamilyIPv6) {
			continue
		}
		rules, err := nft.GetRules(chain.Table, chain)
		if err != nil {
			cleanupErr = errors.Join(cleanupErr, fmt.Errorf("list nftables family %d filter/DOCKER-USER rules: %w", family, err))
			continue
		}
		for _, rule := range rules {
			comment, ok := userdata.GetString(rule.UserData, userdata.TypeComment)
			if !ok || !strings.HasPrefix(comment, prefix) {
				continue
			}
			err := nft.DelRule(rule)
			if err == nil {
				err = nft.Flush()
			}
			if err != nil && !errors.Is(err, unix.ENOENT) {
				cleanupErr = errors.Join(cleanupErr, fmt.Errorf("delete nftables family %d filter/DOCKER-USER rule %d: %w", family, rule.Handle, err))
			}
		}
	}
	return cleanupErr
}
