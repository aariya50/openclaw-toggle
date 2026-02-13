// SPDX-License-Identifier: MIT
// OpenClaw Toggle — Logs viewer for tunnel and node services.

import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - Log Entry
// ---------------------------------------------------------------------------

/// A single line from a service log, tagged with its source.
struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let source: LogSource
    let message: String

    enum LogSource: String, CaseIterable {
        case tunnel = "Tunnel"
        case node   = "Node"

        var color: Color {
            switch self {
            case .tunnel: return .blue
            case .node:   return .purple
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Log Collector
// ---------------------------------------------------------------------------

/// Reads recent log output for the tunnel and node launchd services using
/// the `log` command.  Keeps a rolling buffer of the most recent entries.
@MainActor
final class LogCollector: ObservableObject {

    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var isLoading = false

    /// Maximum entries to keep in memory.
    private let maxEntries = 200

    private var settings: AppSettings { AppSettings.shared }

    /// Fetch recent logs for both services.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        async let tunnelLogs = fetchServiceLogs(
            label: settings.tunnelServiceLabel,
            source: .tunnel
        )
        async let nodeLogs = fetchServiceLogs(
            label: settings.nodeServiceLabel,
            source: .node
        )

        let all = await (tunnelLogs + nodeLogs)
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(maxEntries)

        entries = Array(all)
    }

    /// Clear all collected logs.
    func clear() {
        entries.removeAll()
    }

    // MARK: - Private

    /// Uses `log show` to pull recent entries for a launchd service.
    /// Falls back to reading the service's stdout/stderr log files if the
    /// unified log doesn't have entries.
    private func fetchServiceLogs(
        label: String,
        source: LogEntry.LogSource
    ) async -> [LogEntry] {
        // Try unified log first (last 5 minutes)
        let predicate = "subsystem == '\(label)' OR senderImagePath CONTAINS '\(label)'"
        let logOutput = await runShell(
            "/usr/bin/log",
            arguments: [
                "show",
                "--predicate", predicate,
                "--last", "5m",
                "--style", "compact",
                "--info"
            ]
        )

        var results: [LogEntry] = []

        // Parse unified log output
        let lines = logOutput.components(separatedBy: "\n")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("Timestamp") else { continue }

            // Compact format: "2026-02-13 14:00:00.000000-0800  ... message"
            // Try to extract timestamp from the first ~30 chars
            let entry = LogEntry(
                timestamp: extractTimestamp(from: trimmed) ?? Date(),
                source: source,
                message: trimmed
            )
            results.append(entry)
        }

        // If unified log returned nothing, try reading launchd stdout/stderr
        if results.isEmpty {
            let fallbackLogs = await readLaunchdLogs(label: label, source: source)
            results.append(contentsOf: fallbackLogs)
        }

        return results
    }

    /// Attempts to read stdout/stderr log files that launchd services
    /// commonly write to (e.g. /tmp/<label>.stdout.log).
    private func readLaunchdLogs(
        label: String,
        source: LogEntry.LogSource
    ) async -> [LogEntry] {
        var results: [LogEntry] = []

        // Common log file locations for launchd services
        let logPaths = [
            "/tmp/\(label).stdout.log",
            "/tmp/\(label).stderr.log",
            NSHomeDirectory() + "/Library/Logs/\(label).log",
            NSHomeDirectory() + "/Library/Logs/\(label).stdout.log",
            NSHomeDirectory() + "/Library/Logs/\(label).stderr.log"
        ]

        for path in logPaths {
            // Read last 50 lines using tail
            let output = await runShell("/usr/bin/tail", arguments: ["-n", "50", path])
            guard !output.isEmpty else { continue }

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                results.append(LogEntry(
                    timestamp: extractTimestamp(from: trimmed) ?? Date(),
                    source: source,
                    message: trimmed
                ))
            }
        }

        return results
    }

    /// Best-effort timestamp extraction from a log line.
    private func extractTimestamp(from line: String) -> Date? {
        // Try ISO-ish format at the start: "2026-02-13 14:00:00"
        guard line.count >= 19 else { return nil }
        let prefix = String(line.prefix(19))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: prefix)
    }

    /// Runs a command and returns its trimmed stdout.
    @discardableResult
    private func runShell(_ path: String, arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Logs Viewer View
// ---------------------------------------------------------------------------

/// A compact log viewer that can be shown in a popover section or a sheet.
struct LogsViewer: View {
    @StateObject private var collector = LogCollector()

    /// Filter to show only one source, or nil for all.
    @State private var sourceFilter: LogEntry.LogSource? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Text("Logs")
                    .font(.headline)

                Spacer()

                // Source filter picker
                Picker("", selection: $sourceFilter) {
                    Text("All").tag(LogEntry.LogSource?.none)
                    ForEach(LogEntry.LogSource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(LogEntry.LogSource?.some(source))
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Button {
                    Task { await collector.refresh() }
                } label: {
                    if collector.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(collector.isLoading)
                .help("Refresh Logs")

                Button {
                    collector.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear Logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Log entries
            if filteredEntries.isEmpty && !collector.isLoading {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No log entries")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Click refresh to fetch recent logs")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(filteredEntries) { entry in
                                logLine(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: filteredEntries.count) { _, _ in
                        if let last = filteredEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 320)
        .task {
            await collector.refresh()
        }
    }

    // MARK: - Filtered entries

    private var filteredEntries: [LogEntry] {
        guard let filter = sourceFilter else { return collector.entries }
        return collector.entries.filter { $0.source == filter }
    }

    // MARK: - Log line

    private func logLine(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Source badge
            Text(entry.source.rawValue)
                .font(.caption2.monospaced())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(entry.source.color.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 3))

            // Message
            Text(entry.message)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary.opacity(0.3))
        )
    }
}
