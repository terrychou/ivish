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

struct ParentShellInfo {
    let parentShell: Shell?
    let callbacks: UnsafeMutablePointer<ivish_callbacks_t>?
}

public class Shell: NSObject {
    let stdinStream = thread_stdin
    let stdoutStream = thread_stdout
    let stderrStream = thread_stderr
    let inputFileNo = fileno(thread_stdin)
    let outputFileNo = fileno(thread_stdout)
    let errorFileNo = fileno(thread_stderr)
    var lnReader: LineReader?
    var cmdLnReader: LineReader?
    var promptText: String?
    var runningCmds = [String: CommandInfo]() // [uuid: info]
    var currentForegroundCmd: String? // uuid
    lazy var queue = DispatchQueue(
        label: "com.terrychou.ivish.cmds." + UUID().uuidString,
        qos: .userInitiated)
    private var inputFileHandle: FileHandle?
    var shellInputPipe: UnsafePipe?
    var cmdInputPipe: UnsafePipe?
    var currentInputReceiver: Int32?
    var cmdPipeWriteFd: Int32?
    var inStream: UnsafeMutablePointer<FILE>?
    
    let config = Config()
    lazy var cmdDb = self.readDatabase()
    lazy var intHandler = self.initIntHandler()
    
    var completer: Completer!
    
    let callbacks: UnsafeMutablePointer<ivish_callbacks_t>?
    
    private lazy var aliases = Aliases()
    
    typealias ARGV = UnsafeMutablePointer<UnsafeMutablePointer<CChar>>
    var argc: Int32 = 0
    var argv: ARGV?
    private var isSubshell = false
    private var subshellCmdline: String?
    private var done = false
    private var parentShellInfo: UnsafeMutablePointer<ParentShellInfo>?
    
    @objc public override init() {
        self.callbacks = ios_getContext()?.bindMemory(to: ivish_callbacks_t.self,
                                                      capacity: 1)
        self.shellInputPipe = .init()
        if let sip = self.shellInputPipe {
            self.lnReader = LineReader(input: sip.input,
                                       output: self.outputFileNo)
        } else {
            self.lnReader = nil
        }
        self.cmdInputPipe = .init()
        if let cip = self.cmdInputPipe {
            self.cmdLnReader = LineReader(input: cip.input,
                                          output: self.outputFileNo)
        } else {
            self.cmdLnReader = nil
        }
        super.init()
        self.initShell()
    }
    
    @objc public init(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>>) {
        self.parentShellInfo = ios_getContext()?.bindMemory(to: ParentShellInfo.self,
                                                            capacity: 1)
        self.callbacks = self.parentShellInfo?.pointee.callbacks
        self.isSubshell = true
//        NSLog("ivish (subshell: \(self.isSubshell)) \(String(cString: argv[Int(argc) - 1])) thread stdin: \(self.inputFileNo), stdout: \(self.outputFileNo), stderr: \(self.errorFileNo)")
        super.init()
        self.argc = argc
        self.argv = argv
        self.initSubshell()
    }
}

extension Shell {
    private func initShell() {
        self.inputFileHandle = .init(fileDescriptor: self.inputFileNo,
                                     closeOnDealloc: false)
        self.setupCellsCaculator()
        self.setupPipes()
        self.initConfig()
        self.setupInStream()
        self.setupCompleter()
        self.setupLineReaderCallbacks()
        self.loadHistory()
    }
    
    private var parentShell: Shell? {
        return self.parentShellInfo?.pointee.parentShell
    }
    
    private func initSubshell() {
        // setup in stream
        self.inStream = self.stdinStream
        // setup aliases
        if let ps = self.parentShell {
            self.aliases.import(from: ps.aliases)
        }
    }
    
    private func cleanup() {
        if self.isSubshell {
            if let cmdline = self.subshellCmdline {
                NSLog("ivish done subshell command: \(cmdline)")
                self.subshellCmdline = nil
            }
        } else {
            self.saveHistory()
            self.lnReader = nil
            self.cmdLnReader?.inputFileHandle?.readabilityHandler = nil
            self.cmdLnReader = nil
            self.inputFileHandle?.readabilityHandler = nil
            self.currentInputReceiver = nil
            self.cleanCmdPipe()
            self.shellInputPipe?.cleanup()
            self.cmdInputPipe?.cleanup()
        }
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
    }
    
    private func setupLineReaderCallbacks() {
        self.lnReader?.hintCallback = self.completer.hint
        self.lnReader?.completionCallback = self.completer.complete
        self.lnReader?.sublineCallback = { lineState in
            return self.aliases.translate(cmdline: lineState.buffer).map {
                "= " + $0.term256Colorized(247)
            }
        }
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
        self.inputFileHandle?.readabilityHandler = {
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
    
    func commandTokens(count: Int=0) -> CmdLineTokenizer.Result {
        return try! CmdLineTokenizer(line: self).tokenize(count: count)
    }
    
    /// quote `self` so that it will be treated by ios_system as
    /// one token
    var iosSystemAsOneToken: String {
        return "\"" + self.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    
    /// restored from the above result
    var iosSystemOneTokenRestored: String {
        return self.replacingOccurrences(of: "\\\"", with: "\"")
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
        return line.commandTokens(count: 1).token(at: 0) ?? ""
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
    
    private func runCommand(_ cmd: String) -> Int32 {
        var ret: Int32 = 0
        let uuid = UUID().uuidString
        self.currentForegroundCmd = uuid
        
        let pid = ios_fork()
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
                // setup parent shell context
                var psi = ParentShellInfo(parentShell: self,
                                          callbacks: self.callbacks)
                ios_setContext(&psi)
                ios_setTTYProvider(self.ttyProvider)
                ios_setTTYRestorer(self.ttyRestorer)
                ios_setStreams(self.inStream, self.stdoutStream, self.stderrStream)
                self.setWindowSize()
                ret = ios_system(cmd)
                ios_closeSession(sid)
                self.postCmd(cmd, uuid: uuid)
            }
        }
        
        return ret
    }
    
    private func putString(_ str: String,
                           to targetFileNo: Int32? = nil,
                           force: Bool = false) {
        var target = targetFileNo ?? self.outputFileNo
        if !force &&
            target != self.outputFileNo &&
            (!self.isSubshell ||
             (ios_isatty(self.outputFileNo) != 0 && ios_isatty(target) != 0)) {
            // this is a trick to do best to output to stderr and stdout
            // in order, by outputing stderr to stdout
            target = self.outputFileNo
        }
        str.write(to: target)
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
        while !self.done {
            do {
                self.putString(self.prompt, to: self.errorFileNo, force: true)
                let line = try self.lnReader!.readline()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.putString("\n")
                if line.isEmpty {
                    continue
                }
                try self.handleCmdline(line)
            } catch let lre as LineReaderException {
                switch lre {
                case .eof:
                    self.putString("^D".termColorized(36))
                    self.cleanup()
                    self.done = true
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
    @objc public func runAsSubshell() -> Int32 {
        var ret: Int32 = 0
        let arguments = (0..<self.argc).map {
            String(cString: self.argv![Int($0)])
        }
        if arguments.count > 1 {
            let cmdline = arguments[1...].joined(separator: " ")
            self.subshellCmdline = cmdline
            ret = self.runSubcommand(cmdline, piped: false)
        }
        //TODO: handling for normal args
        self.cleanup()
        
        return ret
    }
    
    /// validate tokenized result
    ///
    /// the given tokenized result is invalid if any:
    /// 1) it has unfinished quoting
    /// 2) it has any invalid delimiter
    ///
    /// an error is thrown if invalid
    private func validateTokenized(_ tokenized: CmdLineTokenizer.Result) throws {
        if let unfinished = tokenized.unfinished {
            throw ShellException.error("unfinished \(unfinished.escape.rawValue)")
        }
        let invalidDelimiters = tokenized.invalidDelimiters()
        if !invalidDelimiters.isEmpty {
            let info = invalidDelimiters.lazy.map { $0.delimiter.str }.joined(separator: " ")
            throw ShellException.error("invalid delimiters \(info)")
        }
    }
    
    @discardableResult
    private func runSubcommand(_ subcmd: String, piped: Bool) -> Int32 {
        var ret: Int32 = 0
        do {
            if piped {
                let _ = self.runCommand(subcmd)
            } else {
                let tokens = subcmd.commandTokens().tokens.map { $0.content }
                try self.handleNestingShell(tokens)
                if try !self.handleInternalCmd(tokens) {
                    if self.isSubshell {
                        // subshell only handle internal commands
                        // or command-not-found
                        ret = 127
                    } else {
                        ret = self.runCommand(subcmd)
                    }
                    switch ret {
                    case 127:
                        throw ShellException.error(
                            "\(tokens.first ?? ""): command not found"
                        )
                    default: break
                    }
                }
            }
        } catch let se as ShellException {
            switch se {
            case .exit:
                self.cleanup()
                self.done = true
            case let .error(msg):
                self.showError(msg)
            }
        } catch {
            NSLog("ivish failed to run subcommand: \(subcmd): \(error)")
        }
        
        return ret
    }
    
    /// prepare piped `subline`:
    /// 1. if it is an internal command, wrap it in a subshell
    /// 2. if it does not exit, wrap it in a subshell so that it
    ///    could report an error
    /// 3. if it is "ivish", wrap it in a subshell to report error
    /// 4. otherwise, return it intact
    private func pipedSubline(_ subline: String) -> String {
        var ret = subline
        if let command = subline.commandTokens(count: 1).token(at: 0) {
            if command == shellName ||
                InternalCommand.hasCommand(command) ||
                !self.availableCommands().contains(command) {
                ret = shellName + " " + subline
            }
        }
        
        return ret
    }
    
    private func handleTokenized(_ tokenized: CmdLineTokenizer.Result) {
        // run subcommand by subcommand
        var subcmd = ""
        var piped = false
        tokenized.enumerateDelimited(delimiters: [.pipe, .command]) { subline, delimiter, stop in
            switch delimiter?.delimiter {
            case .pipe?:
                piped = true
                subcmd += self.pipedSubline(subline) + " | "
            case .command?, nil:
                if piped {
                    subcmd += self.pipedSubline(subline)
                } else {
                    subcmd += subline
                }
                self.runSubcommand(subcmd, piped: piped)
                subcmd = ""
                piped = false
                if self.done {
                    stop = true
                }
            }
        }
    }
    
    private func handleCmdline(_ line: String) throws {
        var cmdline = line
        // expand aliases first
        if let expanded = self.aliases.translate(cmdline: cmdline) {
            cmdline = expanded
        }
        let tokenized = cmdline.commandTokens()
        do {
            // validate this line
            try self.validateTokenized(tokenized)
            // run valid tokenized
            self.handleTokenized(tokenized)
        } catch let se as ShellException {
            if case let .error(msg) = se {
                self.showError(msg)
            }
        } catch {
            NSLog("ivish failed to validate cmdline: \(cmdline): \(error)")
        }
        
    }
}

extension Shell {
    private func handleNestingShell(_ tokens: CmdTokens) throws {
        if tokens.first == shellName {
            try self.nestShell(tokens)
        }
    }
    
    private func handleInternalCmd(_ tokens: CmdTokens) throws -> Bool {
        // return true if handled
        guard let name = tokens.first,
            let cmd = InternalCommand(rawValue: String(name))
            else { return false }
        let handled = true
        switch cmd {
        case .alias:
            try self.cmdAlias(tokens)
        case .exit:
            try self.exitShell()
        case .help:
            self.showHelp(tokens)
        case .history:
            self.shellHistory(tokens)
        case .unalias:
            try self.cmdUnalias(tokens)
        }
        
        return handled
    }
    
    private func showMsg(_ msg: String,
                         in color: Int,
                         bold: Bool? = nil,
                         to targetFileNo: Int32,
                         force: Bool = false) {
        let content = "\(shellName): \(msg)\n"
        let colorized: String
        if let isBold = bold {
            // show in normal mode
            colorized = content.termColorized(color, bold: isBold)
        } else {
            // in 256 colors
            colorized = content.term256Colorized(color)
        }
        self.putString(colorized, to: targetFileNo, force: force)
    }
    
    private func showError(_ msg: String, force: Bool = false) {
        self.showMsg(msg, in: 31, bold: true, to: self.errorFileNo, force: force)
    }
    
    private func showWarn(_ msg: String) {
        self.showMsg(msg, in: 33, bold: false, to: self.outputFileNo)
    }
    
    private func exitShell() throws {
        throw ShellException.exit
    }
    
    func currentHistoryList() -> String? {
        return self.lnReader?.currentHistoryList()
    }
    
    private func shellHistory(_ tokens: CmdTokens) {
        if let list = self.currentHistoryList() ?? self.parentShell?.currentHistoryList() {
            self.putString(list)
        }
    }
    
    private func nestShell(_ tokens: CmdTokens) throws {
        throw ShellException.error("nesting shell not supported")
    }
    
    private func showHelp(_ tokens: CmdTokens) {
        self.runExCommand("call feedkeys(\"\\<C-W>:help ivish\\<Enter>\", 'n')")
    }
}

extension Shell { // aliases
    private func cmdAlias(_ tokens: CmdTokens) throws {
        try self.handleAliasArgs(Array(tokens[1...]))
    }
    
    /// handle arguments given to `alias` command:
    /// 1) add new alias if "name=value" pair;
    /// 2) find and print existing alias if not the = pair
    /// 3) print all existing aliases if no args given
    private func handleAliasArgs(_ args: [String]) throws {
        guard !args.isEmpty else {
            return self.printAllAliases()
        }
        for arg in args {
            let alias = Aliases.parseAlias(from: arg)
            if let rep = alias.replacement {
                // try and add new alias
                if let eMsg = self.aliases.tryAddAlias(name: alias.name,
                                                       replacement: rep) {
                    self.showError("alias: " + eMsg)
                }
            } else {
                // find and print alias with `name`
                self.printReusableAlias(for: arg)
            }
        }
    }
    
    private func printAllAliases() {
        let sortedNames = self.aliases.allNames().sorted()
        for name in sortedNames {
            self.printReusableAlias(for: name)
        }
    }
    
    private func printReusableAlias(for name: String) {
        if let found = self.aliases.reusableAlias(for: name, cmdName: "alias") {
            self.putString(found + "\n")
        } else {
            self.showError("alias: \(name): not found")
        }
    }
    
    /// remove aliases with given names `tokens`
    ///
    /// remove all existing aliases if option "-a" is given,
    /// and all arguments after it will be ignored
    private func cmdUnalias(_ tokens: CmdTokens) throws {
        for token in tokens[1...] {
            if token == "-a" {
                self.removeAllAliases()
                break
            } else if !self.aliases.remove(name: token) {
                self.showError("unalias: \(token): not found")
            }
        }
    }
    
    private func removeAllAliases() {
        for name in self.aliases.allNames() {
            self.aliases.remove(name: name)
        }
    }
}

private typealias CmdTokens = [String]

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
    case alias
    case unalias
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
    
    static func hasCommand(_ command: String) -> Bool {
        return Self(rawValue: command) != nil
    }
}

internal enum TermMode: String {
    case raw
    case line
}

/// character set for shell syntax
/// refer to bash source code syntax.h
extension CharacterSet {
    static let shellBreak = Self(charactersIn: "()<>;&| \t\n")
    static let shellQuote = Self(charactersIn: "\"`'")
    // shell x quote: shell quote + backslash
    static let shellXQuote = Self.shellQuote.union(.init(charactersIn: "\\"))
    static let shellExpansion = Self(charactersIn: "$<>")
    static let shellPathSeparator = Self(charactersIn: "/")
    
    static let illegalAliasName = Self.shellBreak.union(
        Self.shellXQuote.union(
            Self.shellExpansion.union(
                Self.shellPathSeparator)))
}
