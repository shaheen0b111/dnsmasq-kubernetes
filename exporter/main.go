// dnsmasq-exporter — Prometheus metrics exporter for dnsmasq.
//
// Collects metrics from two sources:
//
//  1. CHAOS TXT DNS queries — dnsmasq exposes cache statistics via DNS
//     queries for hits.bind, misses.bind, cachesize.bind, etc.
//     These are queried on each Prometheus scrape.
//
//  2. Log file parsing — tails /var/log/dnsmasq.log for query counts,
//     forward destinations, and response types (cached/forwarded/local).
//
// Usage:
//
//	dnsmasq-exporter --listen-addr=:9153 --dnsmasq-addr=127.0.0.1:53 --log-path=/var/log/dnsmasq.log
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/miekg/dns"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	listenAddr  string
	dnsmasqAddr string
	logPath     string
)

func init() {
	flag.StringVar(&listenAddr, "listen-addr", ":9153", "Address to listen on for metrics")
	flag.StringVar(&dnsmasqAddr, "dnsmasq-addr", "127.0.0.1:53", "dnsmasq DNS address for CHAOS TXT queries")
	flag.StringVar(&logPath, "log-path", "/var/log/dnsmasq.log", "Path to dnsmasq query log")
}

// ---------------------------------------------------------------------------
// CHAOS TXT collector — queries dnsmasq on each Prometheus scrape
// ---------------------------------------------------------------------------

type chaosCollector struct {
	addr            string
	up              *prometheus.Desc
	cacheSize       *prometheus.Desc
	cacheHits       *prometheus.Desc
	cacheMisses     *prometheus.Desc
	cacheInsertions *prometheus.Desc
	cacheEvictions  *prometheus.Desc
}

func newChaosCollector(addr string) *chaosCollector {
	return &chaosCollector{
		addr: addr,
		up: prometheus.NewDesc("dnsmasq_up",
			"Whether dnsmasq is responding to DNS queries (1 = up, 0 = down).",
			nil, nil),
		cacheSize: prometheus.NewDesc("dnsmasq_cache_size",
			"Configured DNS cache size.",
			nil, nil),
		cacheHits: prometheus.NewDesc("dnsmasq_cache_hits_total",
			"Total DNS cache hits since dnsmasq started.",
			nil, nil),
		cacheMisses: prometheus.NewDesc("dnsmasq_cache_misses_total",
			"Total DNS cache misses since dnsmasq started.",
			nil, nil),
		cacheInsertions: prometheus.NewDesc("dnsmasq_cache_insertions_total",
			"Total DNS cache insertions since dnsmasq started.",
			nil, nil),
		cacheEvictions: prometheus.NewDesc("dnsmasq_cache_evictions_total",
			"Total DNS cache evictions since dnsmasq started.",
			nil, nil),
	}
}

func (c *chaosCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.up
	ch <- c.cacheSize
	ch <- c.cacheHits
	ch <- c.cacheMisses
	ch <- c.cacheInsertions
	ch <- c.cacheEvictions
}

func (c *chaosCollector) Collect(ch chan<- prometheus.Metric) {
	// Query cachesize.bind as a liveness check
	val, err := queryCHAOS(c.addr, "cachesize.bind")
	if err != nil {
		ch <- prometheus.MustNewConstMetric(c.up, prometheus.GaugeValue, 0)
		return
	}
	ch <- prometheus.MustNewConstMetric(c.up, prometheus.GaugeValue, 1)
	ch <- prometheus.MustNewConstMetric(c.cacheSize, prometheus.GaugeValue, val)

	if v, err := queryCHAOS(c.addr, "hits.bind"); err == nil {
		ch <- prometheus.MustNewConstMetric(c.cacheHits, prometheus.CounterValue, v)
	}
	if v, err := queryCHAOS(c.addr, "misses.bind"); err == nil {
		ch <- prometheus.MustNewConstMetric(c.cacheMisses, prometheus.CounterValue, v)
	}
	if v, err := queryCHAOS(c.addr, "insertions.bind"); err == nil {
		ch <- prometheus.MustNewConstMetric(c.cacheInsertions, prometheus.CounterValue, v)
	}
	if v, err := queryCHAOS(c.addr, "evictions.bind"); err == nil {
		ch <- prometheus.MustNewConstMetric(c.cacheEvictions, prometheus.CounterValue, v)
	}
}

// queryCHAOS sends a CHAOS TXT query to dnsmasq and returns the numeric value.
func queryCHAOS(addr, name string) (float64, error) {
	msg := new(dns.Msg)
	msg.SetQuestion(dns.Fqdn(name), dns.TypeTXT)
	msg.Question[0].Qclass = dns.ClassCHAOS

	client := &dns.Client{Timeout: 2 * time.Second}
	resp, _, err := client.Exchange(msg, addr)
	if err != nil {
		return 0, err
	}
	if len(resp.Answer) == 0 {
		return 0, fmt.Errorf("no answer for %s", name)
	}

	txt, ok := resp.Answer[0].(*dns.TXT)
	if !ok || len(txt.Txt) == 0 {
		return 0, fmt.Errorf("unexpected answer type for %s", name)
	}

	return strconv.ParseFloat(txt.Txt[0], 64)
}

// ---------------------------------------------------------------------------
// Log-based metrics — tails the dnsmasq log file in the background
// ---------------------------------------------------------------------------

var (
	queriesTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "dnsmasq_queries_total",
		Help: "Total DNS queries received, by query type.",
	}, []string{"type"})

	forwardsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "dnsmasq_forwards_total",
		Help: "Total queries forwarded to upstream DNS servers.",
	}, []string{"to"})

	responsesTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "dnsmasq_responses_total",
		Help: "Total DNS responses by source (cached, forwarded, local).",
	}, []string{"source"})
)

// Log line patterns from dnsmasq --log-queries output:
//
//	query[A] google.com from 127.0.0.1
//	forwarded google.com to 8.8.8.8
//	reply google.com is 142.251.43.14
//	cached google.com is 142.251.43.14
//	config api.dnsmasq.local is 172.18.0.3
//	/etc/hosts myhost is 127.0.0.1
var (
	queryRe   = regexp.MustCompile(`query\[(\w+)\]\s+\S+\s+from\s+`)
	forwardRe = regexp.MustCompile(`forwarded\s+\S+\s+to\s+(\S+)`)
	cachedRe  = regexp.MustCompile(`cached\s+\S+\s+is\s+`)
	replyRe   = regexp.MustCompile(`reply\s+\S+\s+is\s+`)
	configRe  = regexp.MustCompile(`(?:config|/etc/hosts)\s+\S+\s+is\s+`)
)

func parseLine(line string) {
	if m := queryRe.FindStringSubmatch(line); m != nil {
		queriesTotal.WithLabelValues(m[1]).Inc()
		return
	}
	if m := forwardRe.FindStringSubmatch(line); m != nil {
		forwardsTotal.WithLabelValues(m[1]).Inc()
		return
	}
	if cachedRe.MatchString(line) {
		responsesTotal.WithLabelValues("cached").Inc()
		return
	}
	if configRe.MatchString(line) {
		responsesTotal.WithLabelValues("local").Inc()
		return
	}
	if replyRe.MatchString(line) {
		responsesTotal.WithLabelValues("forwarded").Inc()
		return
	}
}

// tailLog continuously reads new lines from the dnsmasq log file.
// It handles log rotation (file truncation) by reopening the file.
func tailLog(path string) {
	for {
		if err := followLog(path); err != nil {
			log.Printf("log tailer: %v (retrying in 5s)", err)
			time.Sleep(5 * time.Second)
		}
	}
}

func followLog(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	// Seek to end — only process new lines from this point forward
	if _, err := f.Seek(0, io.SeekEnd); err != nil {
		return err
	}

	reader := bufio.NewReader(f)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if err != io.EOF {
				return err
			}
			// At EOF — check for log rotation (file was truncated or replaced)
			info, serr := f.Stat()
			if serr != nil {
				return serr
			}
			pos, _ := f.Seek(0, io.SeekCurrent)
			if info.Size() < pos {
				return fmt.Errorf("log file truncated, reopening")
			}
			time.Sleep(250 * time.Millisecond)
			continue
		}

		parseLine(strings.TrimSpace(line))
	}
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	flag.Parse()

	// Register CHAOS TXT collector (queried on each scrape)
	prometheus.MustRegister(newChaosCollector(dnsmasqAddr))

	// Register log-based counters (updated continuously in background)
	prometheus.MustRegister(queriesTotal)
	prometheus.MustRegister(forwardsTotal)
	prometheus.MustRegister(responsesTotal)

	// Start log tailer in background
	go tailLog(logPath)

	// HTTP server
	http.Handle("/metrics", promhttp.Handler())
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `<html><body><h1>dnsmasq Exporter</h1><p><a href="/metrics">Metrics</a></p></body></html>`)
	})

	log.Printf("dnsmasq-exporter listening on %s", listenAddr)
	log.Printf("  dnsmasq: %s", dnsmasqAddr)
	log.Printf("  log:     %s", logPath)
	log.Fatal(http.ListenAndServe(listenAddr, nil))
}
