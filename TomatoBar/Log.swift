import Foundation
import SwiftUI

protocol TBLogEvent: Encodable {
    var type: String { get }
    var timestamp: Date { get }
}

class TBLogEventAppStart: TBLogEvent {
    internal let type = "appstart"
    internal let timestamp: Date = Date()
}

class TBLogEventTransition: TBLogEvent {
    internal let type = "transition"
    internal let timestamp: Date = Date()

    private let event: String
    private let fromState: String
    private let toState: String
    private let project: String

    init(fromContext ctx: TBStateMachine.Context, project: String) {
        event = "\(ctx.event!)"
        fromState = "\(ctx.fromState)"
        toState = "\(ctx.toState)"
        self.project = project
    }
}

private let logFileName = "TomatoBar.log"
private let lineEnd = "\n".data(using: .utf8)!

internal let logger = TBLogger()

class TBLogger {
    private let logHandle: FileHandle?
    private let logURL: URL?
    private let encoder = JSONEncoder()

    init() {
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .secondsSince1970

        let fileManager = FileManager.default
        let resolvedLogURL = fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent(logFileName)
        logURL = resolvedLogURL
        let logPath = resolvedLogURL.path

        if !fileManager.fileExists(atPath: logPath) {
            guard fileManager.createFile(atPath: logPath, contents: nil) else {
                print("cannot create log file")
                logHandle = nil
                return
            }
        }

        logHandle = FileHandle(forUpdatingAtPath: logPath)
        guard logHandle != nil else {
            print("cannot open log file")
            return
        }
    }

    func append(event: TBLogEvent) {
        guard let logHandle = logHandle else {
            return
        }
        do {
            let jsonData = try encoder.encode(event)
            try logHandle.seekToEnd()
            try logHandle.write(contentsOf: jsonData + lineEnd)
            try logHandle.synchronize()
        } catch {
            print("cannot write to log file: \(error)")
        }
    }

    func removeEvents(forProject rawProject: String) {
        guard let logHandle = logHandle,
              let logURL = logURL else {
            return
        }

        let project = rawProject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else {
            return
        }

        do {
            let data = try Data(contentsOf: logURL)
            guard let text = String(data: data, encoding: .utf8) else {
                return
            }

            var keptLines: [String] = []
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = String(rawLine)
                guard let lineData = line.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let loggedProject = (payload["project"] as? String)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      !loggedProject.isEmpty else {
                    keptLines.append(line)
                    continue
                }

                if loggedProject.caseInsensitiveCompare(project) == .orderedSame {
                    continue
                }

                keptLines.append(line)
            }

            let outputText = keptLines.isEmpty ? "" : keptLines.joined(separator: "\n") + "\n"
            let outputData = outputText.data(using: .utf8) ?? Data()
            try logHandle.truncate(atOffset: 0)
            try logHandle.seek(toOffset: 0)
            try logHandle.write(contentsOf: outputData)
            try logHandle.synchronize()
        } catch {
            print("cannot filter log file: \(error)")
        }
    }
}
