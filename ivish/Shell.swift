//
//  Shell.swift
//  ivish
//
//  Created by Terry Chou on 1/9/20.
//  Copyright © 2020 Boogaloo. All rights reserved.
//

import Foundation
import ios_system


private let defaultPrompt = "$ "
private let shellName = "ivish"

internal enum ShellException: Error {
    case exit
    case error(String)
}

public class Shell: NSObject {
    let input: Int32
    let output: Int32
    let error: Int32
    var lnReader: LineReader?
    var cmdLnReader: LineReader?
    var promptText: String?
    var runningCmds = [String: CommandInfo]() // [uuid: info]
    var currentForegroundCmd: String? // uuid
    lazy var queue = DispatchQueue(label: "com.terrychou.ivish.cmds",
                                   qos: .userInitiated)
    lazy var inputFileHandle = FileHandle(fileDescriptor: self.input,
                                          closeOnDealloc: false)
    let shellInputPipe = UnsafePipe()
    let cmdInputPipe = UnsafePipe()
    var currentInputReceiver: Int32?
    var cmdPipeWriteFd: Int32?
    var inStream: UnsafeMutablePointer<FILE>?
    let outStream = thread_stdout
    
    let config = Config()
    lazy var cmdDb = self.readDatabase()
    lazy var intHandler = self.initIntHandler()
    
    var completer: Completer!
    
    let callbacks: UnsafeMutablePointer<ivish_callbacks_t>?
    
    @objc public override init() {
        self.callbacks = ios_getContext()?.bindMemory(to: ivish_callbacks_t.self,
                                                      capacity: 1)
        self.input = fileno(thread_stdin)
        self.output = fileno(thread_stdout)
        self.error = fileno(thread_stderr)
        if let sip = self.shellInputPipe {
            self.lnReader = LineReader(input: sip.input,
                                       output: self.output)
        } else {
            self.lnReader = nil
        }
        if let cip = self.cmdInputPipe {
            self.cmdLnReader = LineReader(input: cip.input,
                                          output: self.output)
        } else {
            self.cmdLnReader = nil
        }
        super.init()
        self.initShell()
    }
}

extension Shell {
    private func initShell() {
        self.setupCellsCaculator()
        self.setupPipes()
        self.initConfig()
        self.setupInStream()
        self.setupCompleter()
        self.loadHistory()
    }
    
    private func cleanup() {
        self.saveHistory()
        self.lnReader = nil
        self.cmdLnReader?.inputFileHandle?.readabilityHandler = nil
        self.cmdLnReader = nil
        self.inputFileHandle.readabilityHandler = nil
        self.currentInputReceiver = nil
        self.cleanCmdPipe()
        self.shellInputPipe?.cleanup()
        self.cmdInputPipe?.cleanup()
    }
    
    private func initConfig() {
        self.config.importFromEnv(
            for: ShellEnvVar.allCases.map { $0.rawValue }
        )
    }
    
    private func setupInStream() {
        guard let p = UnsafePipe() else {
            NSLog("failed to setup command pipe")
            return
        }
        self.inStream = fdopen(p.input, "rb")
        self.cmdPipeWriteFd = p.output
    }
    
    private func setupCompleter() {
        let helper = CompletionHelper(availableCommands: {
            (InternalCommand.commands(for: $0) + self.availableCommands(for: $0)).sorted()
        }, filenames: self.expandFilenames)
        self.completer = Completer(helper: helper)
        self.lnReader?.hintCallback = self.completer.hint
        self.lnReader?.completionCallback = self.completer.complete
    }
    
    private func initIntHandler() -> InterruptHandler? {
        return self.cmdDb.map {
            InterruptHandler(cmdDatabase: $0)
        }
    }
    
    private func readDatabase() -> CommandDatabase? {
        var ret: CommandDatabase?
        do {
            ret = try self.config[.cmdDatabase].map {
                try CommandDatabase(path: $0)
            }
        } catch {
            NSLog("failed to read command database: \(error.localizedDescription)")
        }
        
        return ret
    }
}

extension Shell {
    private func setupPipes() {
        self.currentInputReceiver = self.shellInputPipe?.output
        self.inputFileHandle.readabilityHandler = {
            let data = $0.availableData
            if data.count > 0 {
                if let wfd = self.currentInputReceiver {
                    data.withUnsafeBytes {
                        _ = write(wfd, $0.baseAddress, data.count)
                    }
                } else {
                    NSLog("no current input receiver")
                }
            }
        }
        self.setupCmdPipes()
    }
    
    private func setupCmdPipes() {
        self.cmdLnReader?.readlineAsynchronously { (line, error) in
            var err: Error?
            if let e = error {
                err = e
            } else if let l = line {
                self.putString("\n")
                self.outputToForegroundCmd(l + "\n")
            } else {
                err = ShellException.error("unknown reason")
            }
            if let lre = err as? LineReaderException {
                switch lre {
                case .eof:
                    self.putString("^D".termColorized(36))
                    self.handleEOFForForegroundCmd()
                case .interrupt:
                    self.putString("^C".termColorized(36))
                    self.handleIntForForegroundCmd()
                case .completion(_):
                    break
                case let .error(msg):
                    NSLog("command line reader error: \(msg)")
                }
            } else if let e = err {
                NSLog("failed to read asynchronously for command: \(e.localizedDescription)")
            }
        }
    }
    
    private func outputToForegroundCmd(_ str: String) {
        if let fd = self.cmdPipeWriteFd {
            str.write(to: fd)
        }
    }
    
    private func handleEOFForForegroundCmd() {
        self.cleanCmdPipe()
        self.setupInStream()
    }
    
    private func handleIntForForegroundCmd() {
        if let handler = self.intHandler {
            self.withCurrentCommand {
                if let cmd = $0.intCandidate {
                    handler.handle(
                        cmdName: cmd,
                        output: {
                            self.outputToForegroundCmd($0)
                            self.putString($0)
                    },
                        tid: ios_getThreadId($0.pid),
                        eof: self.handleEOFForForegroundCmd)
                } else {
                    if self.currentTermMode() == .line {
                        self.outputToForegroundCmd("\n")
                        self.putString("\n")
                    }
                    NSLog("failed to get command name for pid \($0.pid)")
                }
            }
        } else {
            NSLog("failed to create interrupt handler")
        }
    }
    
    private func cleanCmdPipe() {
        guard let wfd = self.cmdPipeWriteFd else { return }
        close(wfd)
        fclose(self.inStream)
        self.cmdPipeWriteFd = nil
        self.inStream = nil
    }
}

private extension String {
    func write(to fileDescriptor: FileDescriptor) {
        Darwin.write(fileDescriptor, self, self.utf8.count)
    }
    
    func whitespaceDivided(maxSplits: Int) -> [Substring] {
        return self.split(maxSplits: maxSplits,
                          omittingEmptySubsequences: true,
                          whereSeparator: { $0.isWhitespace })
    }
    
    var commandComponents: [String] {
        return self.whitespaceDivided(maxSplits: 1).map {
            String($0)
        }
    }
}

private extension Array where Element == String {
    func columned(with totalCols: Int, spacing: Int = 2) -> String {
        var maxWidth = 0
        var widths = [Int]()
        for s in self {
            let width = s.width
            widths.append(width)
            if width > maxWidth {
                maxWidth = width
            }
        }
        if maxWidth + spacing > totalCols {
            maxWidth = totalCols - spacing
        }
        let num = totalCols / (maxWidth + spacing)
        var ret = ""
        var i = 0
        let sp = String(repeatElement(" ", count: spacing))
        while i < self.count {
            var w = widths[i]
            var s = self[i]
            if w > maxWidth {
                s = String(s.dropLast(w - maxWidth + 3)) + "..."
                w = s.width
            }
            ret += s.padding(toLength: s.count + maxWidth - w,
                             withPad: " ",
                             startingAt: 0)
            i += 1
            if i % num == 0 {
                ret += "\n"
            } else {
                ret += sp
            }
        }
        
        return ret
    }
}

extension Shell {
    var prompt: String {
        return self.promptText ?? defaultPrompt
    }
    
    private func commandName(from line: String) -> String {
        return line.commandComponents[0]
    }
    
    private func tuneForTermMode(_ mode: TermMode) {
        self.currentInputReceiver = mode == .line ?
            self.cmdInputPipe?.output :
            self.cmdPipeWriteFd
    }
    
    private func tuneTermMode(for cmd: String) {
        let value = self.cmdDb?.property(.termMode, of: cmd)
        let mode = value.flatMap { TermMode(rawValue: $0) } ?? .line
        self.tuneForTermMode(mode)
    }
    
    private func ttyProvider(_ cName: String?,
                             context: NSMutableString?) -> Int32 {
        guard let cn = cName else { return -1 }
        if let ctx = context {
            ctx.append(self.currentTermMode().rawValue)
        }
        self.tuneTermMode(for: cn)
        
        return fileno(self.inStream)
    }
    
    private func ttyRestorer(_ context: String?) {
        guard let ctx = context,
            let mode = TermMode(rawValue: ctx) else { return }
        self.tuneForTermMode(mode)
    }
    
    private func currentTermMode() -> TermMode {
        return self.currentInputReceiver.map {
            $0 == self.cmdPipeWriteFd ? .raw : .line
            } ?? .line
    }
    
    private func preCmd(_ cmd: String,
                        uuid: String,
                        pid: pid_t,
                        sid: UInt) {
        let info = CommandInfo(cmdLine: cmd,
                               pid: pid,
                               sid: sid)
        self.runningCmds[uuid] = info
        // initialize term mode
        let name = self.commandName(from: cmd)
        self.tuneTermMode(for: name)
    }
    
    private func postCmd(_ cmd: String, uuid: String) {
        // remove from running commands
        self.runningCmds[uuid] = nil
        // restore input pipe for shell
        self.currentInputReceiver = self.shellInputPipe?.output
    }
    
    private func withCurrentCommand(_ task: (CommandInfo) -> Void) {
        guard let uuid = self.currentForegroundCmd else { return }
        if let info = self.runningCmds[uuid] {
            task(info)
        }
    }
    
    /// `getenv` got override in ios_system
    /// values of `COLUMNS`, `ROWS` or `LINES` are intercepted
    /// and need to save via `ios_setWindowSize` for each
    /// session
    private func setWindowSize() {
        let width = atoi(getenv("COLUMNS"))
        let height = atoi(getenv("LINES"))
        ios_setWindowSize(width, height)
    }
    
    private func runCommand(_ cmd: String) {
        let uuid = UUID().uuidString
        let pid = ios_fork()
        self.currentForegroundCmd = uuid
        let in_stream = self.inStream
        let out_stream = self.outStream
        
        self.queue.sync {
            uuid.withCString {
                let sid = $0
                thread_stdin = nil
                thread_stdout = nil
                thread_stderr = nil
                self.preCmd(cmd,
                            uuid: uuid,
                            pid: pid,
                            sid: ios_sessionId(sid))
                ios_switchSession(sid)
                ios_setTTYProvider(self.ttyProvider)
                ios_setTTYRestorer(self.ttyRestorer)
                ios_setStreams(in_stream, out_stream, out_stream)
                self.setWindowSize()
                ios_system(cmd)
                ios_closeSession(sid)
                self.postCmd(cmd, uuid: uuid)
            }
        }
    }
    
    private func putString(_ str: String) {
        str.write(to: self.output)
    }
    
    private func shortenFilenames(_ cands: [String]) -> [String] {
        return cands.map {
            guard !$0.isEmpty else { return "" }
            var ret = ($0 as NSString).lastPathComponent
            if $0.last! == "/" {
                ret += "/"
            }
            
            return ret
        }
    }
    
    private func printCandidates(_ c: Completion) {
        let columns = self.config[.columns].flatMap { Int($0) } ?? 80
        self.putString("\n")
        let cands: [String]
        if c.info.type == .filename {
            cands = self.shortenFilenames(c.candidates)
        } else {
            cands = c.candidates
        }
        self.putString(cands.columned(with: columns))
        self.putString("\n")
    }
    
    @objc public func start() {
        if self.lnReader == nil || self.cmdLnReader == nil {
            return // failed to create necessary pipes
        }
        done: while true {
            do {
                self.putString(self.prompt)
                let line = try self.lnReader!.readline()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.putString("\n")
                if line.isEmpty {
                    continue
                }
                let comps = line.commandComponents
                try self.handleNestingShell(comps)
                if try self.handleInternalCmd(comps) {
                    continue
                } else {
                    self.runCommand(line)
                }
            } catch let se as ShellException {
                switch se {
                case .exit:
                    self.cleanup()
                    break done
                case let .error(msg):
                    self.showError(msg)
                }
            } catch let lre as LineReaderException {
                switch lre {
                case .eof:
                    self.putString("^D".termColorized(36))
                    self.cleanup()
                    break done
                case .interrupt:
                    // ^C start a new prompt
                    self.putString("^C\n".termColorized(36))
                case let .completion(c):
                    self.printCandidates(c)
                case let .error(msg):
                    NSLog("line reader error: \(msg)")
                }
            } catch {
                NSLog("failed to read shell input: \(error.localizedDescription)")
            }
        }
    }
}

extension Shell {
    private func handleNestingShell(_ comps: [String]) throws {
        if comps.first == shellName {
            try self.nestShell(comps)
        }
    }
    
    private func handleInternalCmd(_ comps: [String]) throws -> Bool {
        // return true if handled
        guard let name = comps.first,
            let cmd = InternalCommand(rawValue: String(name))
            else { return false }
        let handled = true
        switch cmd {
        case .exit:
            try self.exitShell()
        case .help:
            self.showHelp(comps)
        case .history:
            self.shellHistory(comps)
        }
        
        return handled
    }
    
    private func showMsg(_ msg: String,
                         in color: Int,
                         bold: Bool? = nil) {
        let content = "\(shellName): \(msg)"
        let colorized: String
        if let isBold = bold {
            // show in normal mode
            colorized = content.termColorized(color, bold: isBold)
        } else {
            // in 256 colors
            colorized = content.term256Colorized(color)
        }
        self.putString(colorized)
        self.putString("\n")
    }
    
    private func showError(_ msg: String) {
        self.showMsg(msg, in: 31, bold: true)
    }
    
    private func showWarn(_ msg: String) {
        self.showMsg(msg, in: 33, bold: false)
    }
    
    private func exitShell() throws {
        throw ShellException.exit
    }
    
    private func shellHistory(_ comps: [String]) {
        let list = self.lnReader!.currentHistoryList()
        self.putString(list)
    }
    
    private func nestShell(_ comps: [String]) throws {
        throw ShellException.error("nesting shell not supported")
    }
    
    private func showHelp(_ comps: [String]) {
        self.runExCommand("call feedkeys(\"\\<C-W>:help ivish\\<Enter>\", 'n')")
    }
}

extension Shell {
    private func availableCommands(for pattern: String? = nil) -> [String] {
        return self.callbacks?.pointee.available_commands.map {
            $0(pattern)
        } ?? []
    }
    
    private func runExCommand(_ cmd: String) {
        self.callbacks?.pointee.run_ex_command?(cmd)
    }
    
    private func setupCellsCaculator() {
        if let cc = self.callbacks?.pointee.cells_caculator {
            gCellsCaculator = { cc(Int32($0)) }
        }
    }
    
    private func expandFilenames(_ pattern: String) -> [String] {
        return self.callbacks?.pointee.expand_filenames.map {
            $0(pattern + "*")
        } ?? []
    }
}

extension Shell {
    private var historyFilePath: String? {
        return self.config[.historyPath]
    }
    
    private func loadHistory() {
        guard let path = self.historyFilePath,
            FileManager.default.fileExists(atPath: path)
            else { return }
        do {
            try self.lnReader?.loadHistory(from: path)
        } catch {
            NSLog("failed to load shell history")
        }
    }
    
    private func saveHistory() {
        guard let path = self.historyFilePath else { return }
        do {
            try self.lnReader?.saveHistory(to: path)
        } catch {
            NSLog("failed to save shell history")
        }
    }
}

internal struct UnsafePipe {
    let input: Int32
    let output: Int32
    
    init?() {
        let fds = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer {
            fds.deinitialize(count: 2)
            fds.deallocate()
        }
        if pipe(fds) < 0 {
            NSLog("failed to create unsafe pipe")
            return nil
        } else {
            self.input = fds.pointee
            self.output = fds.advanced(by: 1).pointee
        }
    }
    
    func cleanup() {
        close(self.input)
        close(self.output)
    }
}

internal struct CommandInfo {
    let cmdLine: String
    let pid: pid_t
    let sid: UInt
    
    var intCandidate: String? {
        let rootCmd = ios_getSessionRootCmdName(self.sid)
        let currentCmd = ios_getSessionCurrentCmdName(self.sid)
        
        return rootCmd == currentCmd ? rootCmd : nil
    }
}

internal enum InternalCommand: String, CaseIterable {
    case exit
    case help
    case history
    
    static let allCommands = InternalCommand.allCases.map {
        $0.rawValue
    }.sorted()
    
    static func commands(for pattern: String) -> [String] {
        return pattern.isEmpty ? self.allCommands :
            self.allCommands.filter { $0.hasPrefix(pattern) }
    }
}

internal enum TermMode: String {
    case raw
    case line
}
