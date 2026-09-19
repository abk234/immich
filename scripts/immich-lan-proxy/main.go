// Immich LAN proxy: listen on LAN → forward to Immich on localhost.
// Built as ImmichLanProxy.app so macOS Firewall can allow only this helper.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
)

func main() {
	listenHost := flag.String("listen-host", "0.0.0.0", "address to bind")
	listenPort := flag.Int("listen-port", 2283, "port to bind")
	targetHost := flag.String("target-host", "127.0.0.1", "upstream host")
	targetPort := flag.Int("target-port", 2283, "upstream port")
	pidFile := flag.String("pid-file", "", "optional pid file path")
	daemon := flag.Bool("daemon", false, "detach (parent exits after fork)")
	flag.Parse()

	if *daemon {
		pidAbs := *pidFile
		if pidAbs != "" && !filepath.IsAbs(pidAbs) {
			if abs, err := filepath.Abs(pidAbs); err == nil {
				pidAbs = abs
			}
		}
		exe, err := os.Executable()
		if err != nil {
			log.Fatal(err)
		}
		args := []string{exe,
			"-listen-host", *listenHost,
			"-listen-port", fmt.Sprintf("%d", *listenPort),
			"-target-host", *targetHost,
			"-target-port", fmt.Sprintf("%d", *targetPort),
		}
		if pidAbs != "" {
			args = append(args, "-pid-file", pidAbs)
		}
		attr := &os.ProcAttr{
			Env:   os.Environ(),
			Files: []*os.File{nil, nil, nil},
			Sys:   &syscall.SysProcAttr{Setsid: true},
		}
		p, err := os.StartProcess(exe, args, attr)
		if err != nil {
			log.Fatal(err)
		}
		_ = p.Release()
		os.Exit(0)
	}

	if *pidFile != "" {
		if err := os.WriteFile(*pidFile, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o644); err != nil {
			log.Fatal(err)
		}
	}

	addr := fmt.Sprintf("%s:%d", *listenHost, *listenPort)
	target := fmt.Sprintf("%s:%d", *targetHost, *targetPort)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}
	log.Printf("ImmichLanProxy listening on %s → %s", addr, target)

	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
		<-ch
		_ = ln.Close()
		if *pidFile != "" {
			_ = os.Remove(*pidFile)
		}
		os.Exit(0)
	}()

	for {
		client, err := ln.Accept()
		if err != nil {
			return
		}
		go proxy(client, target)
	}
}

func proxy(client net.Conn, target string) {
	defer client.Close()
	upstream, err := net.Dial("tcp", target)
	if err != nil {
		return
	}
	defer upstream.Close()

	errc := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(upstream, client); errc <- struct{}{} }()
	go func() { _, _ = io.Copy(client, upstream); errc <- struct{}{} }()
	<-errc
}
