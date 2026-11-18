#!/usr/bin/env python3
"""Add Linux TUN ownership to the pinned boxdd build without changing Android."""

import json
from pathlib import Path
import shutil
import subprocess
import sys


source = Path.cwd()
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
netlink, tun = map(Path, subprocess.check_output(
    ['go', 'list', '-mod=readonly', '-f', '{{.Dir}}', 'github.com/sagernet/netlink', 'github.com/sagernet/sing-tun'],
    text=True,
).splitlines())
replacements: dict[str, str] = {}

for name, module in (('netlink', netlink), ('sing-tun', tun)):
    for entry in module.rglob('*'):
        target = output / name / entry.relative_to(module)
        if entry.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(entry, target)

modfile = output / 'recovery.mod'
shutil.copyfile(source / 'go.mod', modfile)
shutil.copyfile(source / 'go.sum', modfile.with_suffix('.sum'))
subprocess.run([
    'go', 'mod', 'edit', f'-modfile={modfile}',
    f'-replace=github.com/sagernet/netlink={output / "netlink"}',
    f'-replace=github.com/sagernet/sing-tun={output / "sing-tun"}',
], check=True)


def overlay(root: Path, name: str, *changes: tuple[str, str, int]) -> None:
    original = root / name
    content = original.read_text()
    for before, after, count in changes:
        if content.count(before) != count:
            raise ValueError(f'{original}: recovery overlay no longer matches {before!r}')
        content = content.replace(before, after)
    if root == source:
        target = output / (root.name + '-' + original.name)
        replacements[str(original)] = str(target)
    else:
        target = output / root.name.partition('@')[0] / original.name
    target.write_text(content)


overlay(netlink, 'rule.go',
    ('type Rule struct {', 'type Rule struct {\n\tProtocol          uint8', 1),
)
overlay(netlink, 'rule_linux.go',
    ('\n\tif rule.Priority >= 0 {', '''
	if rule.Protocol != 0 {
		req.AddData(nl.NewRtAttr(nl.FRA_PROTOCOL, []byte{rule.Protocol}))
	}
	if rule.Priority >= 0 {''', 1),
    ('\t\t\tcase nl.FRA_PRIORITY:', '''			case nl.FRA_PROTOCOL:
				rule.Protocol = attrs[j].Value[0]
			case nl.FRA_PRIORITY:''', 1),
)

overlay(tun, 'tun_linux.go',
    ('\t"slices"\n', '\t"slices"\n\t"strconv"\n', 1),
    ('func New(options Options) (Tun, error) {', '''var ownedTUNProtocol = func() uint8 {
	protocol, _ := strconv.ParseUint(os.Getenv("UTABAKO_TUN_OWNER_PROTOCOL"), 10, 8)
	return uint8(protocol)
}()

func New(options Options) (Tun, error) {
	if ownedTUNProtocol != 0 && (options.NetNs != "" || options.FileDescriptor != 0 || options.EXP_ExternalConfiguration) {
		return nil, E.New("supervised TUN requires a new local interface")
	}''', 1),
    ('unix.Open(controlPath, unix.O_RDWR, 0)', 'unix.Open(controlPath, unix.O_RDWR|unix.O_CLOEXEC, 0)', 1),
    ('\tflags := unix.IFF_TUN | unix.IFF_NO_PI', '''	flags := unix.IFF_TUN | unix.IFF_NO_PI
	if ownedTUNProtocol != 0 {
		flags |= unix.IFF_TUN_EXCL
	}''', 1),
    ('\t\terr := netlink.RuleAdd(rule)', '\t\trule.Protocol = ownedTUNProtocol\n\t\terr := netlink.RuleAdd(rule)', 1),
    ('''func (t *NativeTun) unsetRules() error {
	if t.options.FileDescriptor > 0 {
		return nil
	}''', '''func (t *NativeTun) unsetRules() error {
	if t.options.FileDescriptor > 0 {
		return nil
	}
	if ownedTUNProtocol != 0 {
		rules, err := netlink.RuleList(netlink.FAMILY_ALL)
		if err != nil {
			return err
		}
		for _, installed := range rules {
			if installed.Protocol == ownedTUNProtocol {
				rule := netlink.NewRule()
				rule.Family, rule.Priority, rule.Protocol = installed.Family, installed.Priority, installed.Protocol
				if err := netlink.RuleDel(rule); err != nil && !errors.Is(err, unix.ENOENT) {
					return E.Cause(err, "unset owned TUN rule ", installed.Priority)
				}
			}
		}
		return nil
	}''', 1),
    ('''\tgo func() {
		_ = shell.Exec(ctlPath, "domain", t.options.Name, "~.").Run()
		_ = shell.Exec(ctlPath, "default-route", t.options.Name, "true").Run()
		_ = shell.Exec(ctlPath, append([]string{"dns", t.options.Name}, common.Map(dnsAddress, netip.Addr.String)...)...).Run()
	}()''', '''	if ownedTUNProtocol != 0 {
		link, err := netlink.LinkByName(t.options.Name)
		if err != nil {
			return err
		}
		// resolved owns DNS per link index; RTM_DELLINK discards the link's DNS state.
		linkIndex := strconv.Itoa(link.Attrs().Index)
		_ = shell.Exec(ctlPath, "domain", linkIndex, "~.").Run()
		_ = shell.Exec(ctlPath, "default-route", linkIndex, "true").Run()
		_ = shell.Exec(ctlPath, append([]string{"dns", linkIndex}, common.Map(dnsAddress, netip.Addr.String)...)...).Run()
		return nil
	}
	go func() {
		_ = shell.Exec(ctlPath, "domain", t.options.Name, "~.").Run()
		_ = shell.Exec(ctlPath, "default-route", t.options.Name, "true").Run()
		_ = shell.Exec(ctlPath, append([]string{"dns", t.options.Name}, common.Map(dnsAddress, netip.Addr.String)...)...).Run()
	}()''', 1),
)
overlay(tun, 'redirect_route_linux.go',
    ('\t\terr = netlink.RuleAdd(rule)', '\t\trule.Protocol = ownedTUNProtocol\n\t\terr = netlink.RuleAdd(rule)', 2),
    ('\t\t_ = netlink.RuleDel(rule)', '\t\trule.Protocol = ownedTUNProtocol\n\t\t_ = netlink.RuleDel(rule)', 2),
    ('\t\t_ = netlink.RouteDel(&route)', '''		if ownedTUNProtocol == 0 || route.Protocol == netlink.RouteProtocol(ownedTUNProtocol) {
			_ = netlink.RouteDel(&route)
		}''', 1),
    ('\t\tif len(routeList) == 0 || fErr != nil {', '''		if fErr != nil && ownedTUNProtocol != 0 {
			return E.Cause(fErr, "check redirect route table")
		}
		if len(routeList) == 0 || fErr != nil {''', 1),
    ('\t\tkey, isRedirectRoute := redirectRouteKeyFromRoute(route)', '''		if ownedTUNProtocol != 0 && route.Protocol != netlink.RouteProtocol(ownedTUNProtocol) {
			continue
		}
		key, isRedirectRoute := redirectRouteKeyFromRoute(route)''', 1),
    ('\t\tTable:     tableIndex,', '\t\tTable:     tableIndex,\n\t\tProtocol:  netlink.RouteProtocol(ownedTUNProtocol),', 1),
)
overlay(tun, 'redirect_nftables_rules_openwrt.go',
    ('\trulePath := "/etc/nftables.d/', '''	if ownedTUNProtocol != 0 {
		return E.New("supervised TUN does not modify OpenWrt fw4 configuration")
	}
	rulePath := "/etc/nftables.d/''', 1),
)
overlay(source, 'protocol/tun/inbound.go',
    ('\t\t\tt.autoRedirect, err = tun.NewAutoRedirect', '''			tableName := os.Getenv("UTABAKO_TUN_OWNER_TABLE")
			if tableName == "" {
				tableName = "sing-box"
			}
			t.autoRedirect, err = tun.NewAutoRedirect''', 1),
    ('TableName:              "sing-box",', 'TableName:              tableName,', 1),
)
overlay(source, 'daemon/instance.go',
    ('\t"net/netip"', '\t"net/netip"\n\t"os"', 1),
    ('\tif overrideOptions != nil {', '''	if os.Getenv("UTABAKO_TUN_OWNER_TABLE") != "" {
		tunCount := 0
		for _, inbound := range options.Inbounds {
			if _, ok := inbound.Options.(*option.TunInboundOptions); ok {
				tunCount++
			}
		}
		if tunCount > 1 {
			cancel()
			return nil, E.New("supervised boxdd supports one TUN inbound")
		}
	}
	if overrideOptions != nil {''', 1),
)
overlay(source, 'experimental/boxdd/cmd_run_linux.go',
    ('func runService() (bool, error) {', '''func runService() (bool, error) {
	if os.Getenv("UTABAKO_TUN_OWNER_PROTOCOL") == "" || os.Getenv("UTABAKO_TUN_OWNER_TABLE") == "" {
		return true, E.New("launch boxdd with its Linux recovery supervisor")
	}''', 1),
)
(output / 'overlay.json').write_text(json.dumps({'Replace': replacements}))
