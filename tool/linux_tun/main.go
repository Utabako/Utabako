package main

import (
	"cmp"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/gofrs/uuid/v5"
	"github.com/sagernet/sing-box/daemon"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/emptypb"
)

const (
	connectionInterval = time.Second
	closedLimit        = 100
	logLimit           = 200
)

func main() {
	socket := flag.String("socket", "", "boxdd Unix socket path")
	flag.Usage = func() {
		fmt.Fprintln(flag.CommandLine.Output(), "usage: diagnostics -socket PATH {start <config> | stop | serve <web-dir> <listen-address> <access-url-file>}")
	}
	flag.Parse()
	if err := run(*socket, flag.Args()); err != nil {
		log.Fatal(err)
	}
}

func run(socket string, args []string) error {
	if socket == "" || len(args) == 0 {
		flag.Usage()
		return errors.New("socket path and command are required")
	}
	path, err := filepath.Abs(socket)
	if err != nil {
		return fmt.Errorf("resolve boxdd socket: %w", err)
	}
	conn, err := grpc.NewClient("passthrough:///boxdd",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", path)
		}),
	)
	if err != nil {
		return fmt.Errorf("create boxdd client: %w", err)
	}
	defer conn.Close()

	switch {
	case args[0] == "start" && len(args) == 2:
		config, err := os.ReadFile(args[1])
		if err != nil {
			return fmt.Errorf("read config: %w", err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if _, err := NewDesktopServiceClient(conn).StartService(ctx, &StartServiceRequest{ConfigContent: string(config)}); err != nil {
			return fmt.Errorf("boxdd StartService: %w", err)
		}
		return nil
	case args[0] == "stop" && len(args) == 1:
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if _, err := daemon.NewManagedServiceClient(conn).StopService(ctx, &emptypb.Empty{}); err != nil {
			return fmt.Errorf("boxdd StopService: %w", err)
		}
		return nil
	case args[0] == "serve" && len(args) == 4:
		return serve(daemon.NewStartedServiceClient(conn), args[1], args[2], args[3])
	default:
		flag.Usage()
		return errors.New("invalid command or argument count")
	}
}

type connection struct {
	ID            string   `json:"id"`
	Host          string   `json:"host"`
	Destination   string   `json:"destination"`
	Source        string   `json:"source"`
	Rule          string   `json:"rule"`
	Outbound      string   `json:"outbound"`
	Chain         []string `json:"chain"`
	Protocol      string   `json:"protocol"`
	Process       *string  `json:"process"`
	Inbound       string   `json:"inbound"`
	StartedAt     int64    `json:"startedAt"`
	ClosedAt      *int64   `json:"closedAt"`
	UploadRate    int64    `json:"uploadRate"`
	DownloadRate  int64    `json:"downloadRate"`
	UploadBytes   int64    `json:"uploadBytes"`
	DownloadBytes int64    `json:"downloadBytes"`
}

type logLine struct {
	Sequence int64  `json:"sequence"`
	Time     int64  `json:"time"`
	Level    string `json:"level"`
	Source   string `json:"source"`
	Message  string `json:"message"`
}

type snapshot struct {
	Active []connection `json:"active"`
	Closed []connection `json:"closed"`
	Logs   []logLine    `json:"logs"`
	Error  *string      `json:"error"`
}

type diagnostics struct {
	mu              sync.Mutex
	active          map[string]connection
	closed          []connection
	logs            []logLine
	logSequence     int64
	connectionError string
	logError        string
}

func (d *diagnostics) snapshot() snapshot {
	d.mu.Lock()
	result := snapshot{
		Active: make([]connection, 0, len(d.active)),
		Closed: append([]connection{}, d.closed...),
		Logs:   append([]logLine{}, d.logs...),
	}
	for _, row := range d.active {
		result.Active = append(result.Active, row)
	}
	status := d.connectionError
	if d.logError != "" {
		if status != "" {
			status += "; "
		}
		status += d.logError
	}
	d.mu.Unlock()
	if status != "" {
		result.Error = &status
	}
	slices.SortFunc(result.Active, func(a, b connection) int {
		if order := cmp.Compare(b.StartedAt, a.StartedAt); order != 0 {
			return order
		}
		return cmp.Compare(a.ID, b.ID)
	})
	return result
}

func connectionRow(id string, p *daemon.Connection) connection {
	host := p.GetDomain()
	if host == "" {
		var err error
		host, _, err = net.SplitHostPort(p.GetDestination())
		if err != nil {
			host = p.GetDestination()
		}
	}
	protocol := p.GetProtocol()
	if protocol == "" {
		protocol = p.GetNetwork()
	}
	row := connection{
		ID: id, Host: host, Destination: p.GetDestination(),
		Source: p.GetSource(), Rule: p.GetRule(), Outbound: p.GetOutbound(),
		Chain: append([]string{}, p.GetChainList()...), Protocol: protocol,
		Inbound: p.GetInbound(), StartedAt: p.GetCreatedAt(),
		UploadBytes: p.GetUplinkTotal(), DownloadBytes: p.GetDownlinkTotal(),
	}
	if path := p.GetProcessInfo().GetProcessPath(); path != "" {
		row.Process = &path
	} else if packages := p.GetProcessInfo().GetPackageNames(); len(packages) > 0 {
		row.Process = &packages[0]
	}
	if closedAt := p.GetClosedAt(); closedAt != 0 {
		row.ClosedAt = &closedAt
	}
	return row
}

func (d *diagnostics) closedIndex(id string) int {
	return slices.IndexFunc(d.closed, func(row connection) bool { return row.ID == id })
}

func (d *diagnostics) archive(row connection, existing int) {
	delete(d.active, row.ID)
	if existing >= 0 {
		d.closed = slices.Delete(d.closed, existing, existing+1)
	}
	// The core sends its initial archive oldest first. For equal timestamps,
	// retain the later event first; unknown closure times sort last.
	timeOf := func(c connection) int64 {
		if c.ClosedAt == nil {
			return 0
		}
		return *c.ClosedAt
	}
	index, _ := slices.BinarySearchFunc(d.closed, row, func(a, b connection) int {
		return cmp.Compare(timeOf(b), timeOf(a))
	})
	if index < closedLimit {
		d.closed = slices.Insert(d.closed, index, row)
		if len(d.closed) > closedLimit {
			d.closed = slices.Delete(d.closed, closedLimit, len(d.closed))
		}
	}
}

func (d *diagnostics) applyConnections(batch *daemon.ConnectionEvents) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if batch.GetReset_() {
		clear(d.active)
		d.closed = nil
		d.connectionError = ""
	}
	for _, event := range batch.GetEvents() {
		id := event.GetId()
		p := event.GetConnection()
		switch event.GetType() {
		case daemon.ConnectionEventType_CONNECTION_EVENT_NEW:
			if p == nil {
				continue
			}
			row := connectionRow(id, p)
			archived := d.closedIndex(id)
			if row.ClosedAt != nil {
				d.archive(row, archived)
			} else if archived < 0 {
				d.active[id] = row
			}
		case daemon.ConnectionEventType_CONNECTION_EVENT_UPDATE:
			if row, ok := d.active[id]; ok {
				// Deltas from the requested one-second interval are bytes/second.
				row.UploadRate, row.DownloadRate = event.GetUplinkDelta(), event.GetDownlinkDelta()
				row.UploadBytes += row.UploadRate
				row.DownloadBytes += row.DownloadRate
				d.active[id] = row
			}
		case daemon.ConnectionEventType_CONNECTION_EVENT_CLOSED:
			archived := d.closedIndex(id)
			row, active := d.active[id]
			switch {
			case p != nil:
				row = connectionRow(id, p)
			case !active && archived >= 0:
				row = d.closed[archived]
			case !active:
				continue
			}
			if closedAt := event.GetClosedAt(); closedAt != 0 {
				row.ClosedAt = &closedAt
			} else if row.ClosedAt == nil && archived >= 0 {
				row.ClosedAt = d.closed[archived].ClosedAt
			}
			row.UploadRate, row.DownloadRate = 0, 0
			d.archive(row, archived)
		}
	}
}

var (
	logColor   = regexp.MustCompile(`\x1b\[[0-9;]*m`)
	logPrefix  = regexp.MustCompile(`^(?:PANIC|FATAL|ERROR|WARN|INFO|DEBUG|TRACE)\[-?[0-9]+\] `)
	logContext = regexp.MustCompile(`^\[[0-9]+ [^\]\r\n]+\] `)
	logSource  = regexp.MustCompile(`^((?:certificate|netns|connection|network|httpclient|clash-mode|reference|router|dns|cache-file|v2ray-api|ntp)|(?:dns|endpoint|inbound|service|outbound|certificate-provider)/[a-z0-9_-]+(?:\[[^\]\r\n]*\])?): `)
)

func (d *diagnostics) applyLogs(batch *daemon.Log) {
	// The core sends a level and formatted message, whose timestamp is relative
	// to the logger's private base time. The wall time here is the receipt time.
	receivedAt := time.Now().UnixMilli()
	d.mu.Lock()
	defer d.mu.Unlock()
	if batch.GetReset_() {
		d.logs = nil
		d.logError = ""
	}
	messages := batch.GetMessages()
	if skipped := len(messages) - logLimit; skipped > 0 {
		d.logSequence += int64(skipped)
		messages = messages[skipped:]
	}
	if excess := len(d.logs) + len(messages) - logLimit; excess > 0 {
		d.logs = slices.Delete(d.logs, 0, excess)
	}
	for _, entry := range messages {
		d.logSequence++
		line := logLine{
			Sequence: d.logSequence, Time: receivedAt,
			Level:   strings.ToLower(entry.GetLevel().String()),
			Message: logColor.ReplaceAllString(entry.GetMessage(), ""),
		}
		if prefix := logPrefix.FindString(line.Message); prefix != "" {
			line.Message = line.Message[len(prefix):]
			prefix := logContext.FindString(line.Message)
			if source := logSource.FindStringSubmatch(line.Message[len(prefix):]); source != nil {
				line.Source = source[1]
				line.Message = prefix + line.Message[len(prefix)+len(source[0]):]
			}
		}
		d.logs = append(d.logs, line)
	}
}

func watchStream[T any](ctx context.Context, d *diagnostics, name string, streamError *string, subscribe func(context.Context) (grpc.ServerStreamingClient[T], error), apply func(*T)) {
	for ctx.Err() == nil {
		stream, err := subscribe(ctx)
		if err == nil {
			for {
				var batch *T
				batch, err = stream.Recv()
				if err != nil {
					break
				}
				apply(batch)
			}
		}
		if ctx.Err() != nil {
			return
		}
		if errors.Is(err, io.EOF) {
			err = errors.New("stream ended")
		}
		d.mu.Lock()
		*streamError = name + ": " + err.Error()
		d.mu.Unlock()
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}

func serve(client daemon.StartedServiceClient, webDir, address, accessFile string) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("listen address must be IPv4 loopback with a port: %w", err)
	}
	ip, err := netip.ParseAddr(host)
	if err != nil || !ip.Is4() || !ip.IsLoopback() {
		return errors.New("listen address must be IPv4 loopback with a port")
	}
	root, err := os.OpenRoot(webDir)
	if err != nil {
		return fmt.Errorf("open web directory: %w", err)
	}
	defer root.Close()
	listener, err := net.Listen("tcp4", address)
	if err != nil {
		return fmt.Errorf("listen for diagnostics HTTP: %w", err)
	}
	defer listener.Close()
	bound := listener.Addr().(*net.TCPAddr)
	authority := bound.String()
	origin := "http://" + authority
	if bound.Port == 80 {
		origin = "http://" + host
	}
	var secret [32]byte
	rand.Read(secret[:])
	token := hex.EncodeToString(secret[:])
	file, err := os.OpenFile(accessFile, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("create private access URL file: %w", err)
	}
	defer os.Remove(accessFile)
	_, writeErr := fmt.Fprintf(file, "%s/#%s\n", origin, token)
	if err := errors.Join(writeErr, file.Close()); err != nil {
		return fmt.Errorf("write private access URL: %w", err)
	}
	state := &diagnostics{
		active:          make(map[string]connection),
		connectionError: "waiting for boxdd connection snapshot",
		logError:        "waiting for boxdd log snapshot",
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go watchStream(ctx, state, "boxdd connection stream", &state.connectionError, func(ctx context.Context) (grpc.ServerStreamingClient[daemon.ConnectionEvents], error) {
		return client.SubscribeConnections(ctx, &daemon.SubscribeConnectionsRequest{Interval: int64(connectionInterval)})
	}, state.applyConnections)
	go watchStream(ctx, state, "boxdd log stream", &state.logError, func(ctx context.Context) (grpc.ServerStreamingClient[daemon.Log], error) {
		return client.SubscribeLog(ctx, &emptypb.Empty{})
	}, state.applyLogs)

	files := http.FileServerFS(root.FS())
	server := &http.Server{
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Host != authority && !(bound.Port == 80 && r.Host == host) {
				http.Error(w, "invalid loopback host", http.StatusForbidden)
				return
			}
			w.Header().Set("Cross-Origin-Resource-Policy", "same-origin")
			if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" && site != "none" {
				http.Error(w, "same origin required", http.StatusForbidden)
				return
			}
			origins := r.Header.Values("Origin")
			if len(origins) > 0 && (len(origins) != 1 || origins[0] != origin) {
				http.Error(w, "same origin required", http.StatusForbidden)
				return
			}
			if r.URL.Path == "/diagnostics/snapshot" || r.URL.Path == "/diagnostics/close" {
				w.Header().Set("Cache-Control", "no-store")
				if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+token)) != 1 {
					http.Error(w, "open the private diagnostics URL", http.StatusUnauthorized)
					return
				}
			}
			switch r.URL.Path {
			case "/diagnostics/snapshot":
				if r.Method != http.MethodGet {
					w.Header().Set("Allow", http.MethodGet)
					http.Error(w, "GET required", http.StatusMethodNotAllowed)
					return
				}
				w.Header().Set("Content-Type", "application/json")
				_ = json.NewEncoder(w).Encode(state.snapshot())
			case "/diagnostics/close":
				if r.Method != http.MethodPost {
					w.Header().Set("Allow", http.MethodPost)
					http.Error(w, "POST required", http.StatusMethodNotAllowed)
					return
				}
				if len(origins) != 1 {
					http.Error(w, "same origin required", http.StatusForbidden)
					return
				}
				closeConnection(w, r, client)
			default:
				if r.Method != http.MethodGet && r.Method != http.MethodHead {
					w.Header().Set("Allow", "GET, HEAD")
					http.Error(w, "GET or HEAD required", http.StatusMethodNotAllowed)
					return
				}
				files.ServeHTTP(w, r)
			}
		}),
	}
	fmt.Printf("Diagnostics listening on %s; private URL saved to %s\n", origin, accessFile)
	if err := server.Serve(listener); err != nil {
		return fmt.Errorf("serve diagnostics HTTP: %w", err)
	}
	return nil
}

func closeConnection(w http.ResponseWriter, r *http.Request, client daemon.StartedServiceClient) {
	var request struct {
		ID string `json:"id"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil || decoder.Decode(new(any)) != io.EOF {
		http.Error(w, "invalid JSON body; expected a connection ID", http.StatusBadRequest)
		return
	}
	id, err := uuid.FromString(request.ID)
	if err != nil || id == uuid.Nil {
		http.Error(w, "invalid connection ID", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if _, err := client.CloseConnection(ctx, &daemon.CloseConnectionRequest{Id: id.String()}); err != nil {
		http.Error(w, fmt.Sprintf("boxdd CloseConnection: %v", err), http.StatusBadGateway)
		return
	}
	// Only a stream event may move a connection to the closed archive.
	w.WriteHeader(http.StatusNoContent)
}
