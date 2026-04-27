package add_header_plugin

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Config holds the plugin configuration
type Config struct {
	Headers map[string]string `json:"headers"`
}

// CreateConfig returns the default plugin configuration
func CreateConfig() *Config {
	return &Config{
		Headers: map[string]string{
			"X-Short-Path":  "Header<Request-Path:^(.{0,4})>, host=Header<Host:(.*)>, agent=Header<User-Agent:(.*)>",
			"X-Short-Path2": "Header<Request-Path:.*>Sub<test(.*path):hello>",
			"X-Short-Agent": "Header<User-Agent:(.*)>Sub<\\b([A-Za-z]+)/[A-Za-z0-9.]+\\b:$1/X>",
		},
	}
}

// Plugin represents the main plugin instance
type Plugin struct {
	next            http.Handler
	headerTemplates map[string]string
	headerRegex     *regexp.Regexp
	subRegex        *regexp.Regexp
}

// TimingResponseWriter wraps http.ResponseWriter to add timing headers
type TimingResponseWriter struct {
	http.ResponseWriter
	startTime     time.Time
	headerWritten bool
	statusCode    int
}

// New creates a new plugin instance
func New(ctx context.Context, next http.Handler, config *Config, name string) (http.Handler, error) {
	if err := validateConfig(config); err != nil {
		return nil, fmt.Errorf("invalid configuration: %w", err)
	}

	return &Plugin{
		next:            next,
		headerTemplates: config.Headers,
		headerRegex:     regexp.MustCompile(`Header<([^:]+):([^>]+)>`),
		subRegex:        regexp.MustCompile(`Sub<([^:]+):([^>]*)>`),
	}, nil
}

// ServeHTTP implements the http.Handler interface
func (p *Plugin) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	// Skip processing for WebSocket requests
	if isWebSocketRequest(req) {
		p.next.ServeHTTP(rw, req)
		return
	}

	// Process request headers
	p.processRequestHeaders(req)

	// Wrap response writer for timing
	wrappedRW := &TimingResponseWriter{
		ResponseWriter: rw,
		startTime:      time.Now(),
	}

	// Ensure timing header is set
	defer wrappedRW.ensureTimingHeader()

	p.next.ServeHTTP(wrappedRW, req)
}

// processRequestHeaders processes and sets request headers based on templates
func (p *Plugin) processRequestHeaders(req *http.Request) {
	req.Header.Set("Request-Path", req.URL.Path)

	for headerName, template := range p.headerTemplates {
		if result := p.processTemplate(template, req); result != "" {
			req.Header.Set(headerName, result)
		}
	}
}

// processTemplate processes a header template string
func (p *Plugin) processTemplate(template string, req *http.Request) string {
	result := template
	functionRegex := regexp.MustCompile(`(Header<[^>]+>|Sub<[^>]+>)`)

	// First expand Header<> functions into concrete values.
	for _, function := range functionRegex.FindAllString(result, -1) {
		if strings.HasPrefix(function, "Header<") {
			replacement := p.processHeaderFunction(function, req)
			result = strings.Replace(result, function, replacement, 1)
		}
	}

	// Then apply Sub<> functions to the expanded string.
	for _, function := range functionRegex.FindAllString(result, -1) {
		if strings.HasPrefix(function, "Sub<") {
			result = p.processSubFunction(function, result)
		}
	}

	return result
}

// processHeaderFunction processes Header<Source:Pattern> functions
func (p *Plugin) processHeaderFunction(headerFunc string, req *http.Request) string {
	matches := p.headerRegex.FindStringSubmatch(headerFunc)
	if len(matches) != 3 {
		return ""
	}

	source := strings.TrimSpace(matches[1])
	patternStr := strings.TrimSpace(matches[2])

	pattern, err := regexp.Compile(patternStr)
	if err != nil {
		return ""
	}

	sourceValue := req.Header.Get(source)
	regexMatches := pattern.FindStringSubmatch(sourceValue)

	switch len(regexMatches) {
	case 0:
		return ""
	case 1:
		return regexMatches[0] // Full match
	default:
		return regexMatches[1] // First capture group
	}
}

// processSubFunction processes Sub<Pattern:Replacement> functions
func (p *Plugin) processSubFunction(subFunc, currentString string) string {
	matches := p.subRegex.FindStringSubmatch(subFunc)
	if len(matches) != 3 {
		return currentString
	}

	patternStr := strings.TrimSpace(matches[1])
	replacement := strings.TrimSpace(matches[2])

	pattern, err := regexp.Compile(patternStr)
	if err != nil {
		return currentString
	}

	// Remove the Sub function from the string first.
	stringWithoutSubFunc := strings.Replace(currentString, subFunc, "", 1)

	return pattern.ReplaceAllString(stringWithoutSubFunc, replacement)
}

// WriteHeader implements http.ResponseWriter.WriteHeader
func (trw *TimingResponseWriter) WriteHeader(statusCode int) {
	trw.statusCode = statusCode

	// Skip timing headers for WebSocket upgrades
	if statusCode != 101 {
		trw.setTimingHeaders()
	}

	trw.ResponseWriter.WriteHeader(statusCode)
}

// Write implements http.ResponseWriter.Write
func (trw *TimingResponseWriter) Write(data []byte) (int, error) {
	if trw.statusCode == 0 {
		trw.WriteHeader(http.StatusOK)
	} else {
		trw.ensureTimingHeader()
	}

	return trw.ResponseWriter.Write(data)
}

// setTimingHeaders sets the timing-related response headers
func (trw *TimingResponseWriter) setTimingHeaders() {
	if trw.headerWritten {
		return
	}

	duration := time.Since(trw.startTime)
	timeValue := strconv.FormatFloat(duration.Seconds(), 'f', -1, 64)

	headers := trw.ResponseWriter.Header()
	headers.Set("X-Request-Time", timeValue)
	headers.Set("Server-Timing", fmt.Sprintf("total;dur=%.3f", duration.Seconds()*1000))

	trw.headerWritten = true
}

// ensureTimingHeader ensures timing header is set (used in defer)
func (trw *TimingResponseWriter) ensureTimingHeader() {
	if trw.statusCode == 0 {
		trw.WriteHeader(http.StatusOK)
	} else if trw.statusCode != 101 { // Not WebSocket upgrade
		trw.setTimingHeaders()
	}
}

// isWebSocketRequest checks if the request is a WebSocket upgrade
func isWebSocketRequest(req *http.Request) bool {
	connection := strings.ToLower(req.Header.Get("Connection"))
	upgrade := strings.ToLower(req.Header.Get("Upgrade"))
	return strings.Contains(connection, "upgrade") && upgrade == "websocket"
}

// validateConfig validates the plugin configuration
func validateConfig(config *Config) error {
	headerRegex := regexp.MustCompile(`Header<([^:]+):([^>]+)>`)
	subRegex := regexp.MustCompile(`Sub<([^:]+):([^>]*)>`)

	for headerName, template := range config.Headers {
		// Validate Header<> patterns
		for _, match := range headerRegex.FindAllStringSubmatch(template, -1) {
			if len(match) == 3 {
				pattern := strings.TrimSpace(match[2])
				if _, err := regexp.Compile(pattern); err != nil {
					return fmt.Errorf("invalid regex pattern '%s' in header '%s': %w", pattern, headerName, err)
				}
			}
		}

		// Validate Sub<> patterns
		for _, match := range subRegex.FindAllStringSubmatch(template, -1) {
			if len(match) == 3 {
				pattern := strings.TrimSpace(match[1])
				if _, err := regexp.Compile(pattern); err != nil {
					return fmt.Errorf("invalid regex pattern '%s' in header '%s': %w", pattern, headerName, err)
				}
			}
		}
	}

	return nil
}

// Debug is a placeholder for debug logging (currently disabled)
func Debug(format string, v ...interface{}) {
	// Uncomment the line below to enable debug logging
	// log.Printf(format, v...)
}
