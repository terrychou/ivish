//
//  LineReader.swift
//  ivish
//
//  Created by Terry Chou on 1/11/20.
//  Copyright © 2020 Boogaloo. All rights reserved.
//

import Foundation


public typealias FileDescriptor = Int32
public typealias CellsCaculator = (Int) -> Int32
public var gCellsCaculator: CellsCaculator = { _ in 1 }

internal enum ControlChar: UInt8 {
    case null      = 0
    case c_a       = 1
    case c_b       = 2
    case c_c       = 3
    case c_d       = 4
    case c_e       = 5
    case c_f       = 6
    case bell      = 7
    case c_h       = 8
    case tab       = 9
    case c_k       = 11
    case c_l       = 12
    case enter     = 13
    case c_n       = 14
    case c_p       = 16
    case c_t       = 20
    case c_u       = 21
    case c_w       = 23
    case c_y       = 25
    case esc       = 27
    case backspace = 127
    
    var char: Character {
        return Character(UnicodeScalar(Int(self.rawValue))!)
    }
}

public enum AnsiCode {
    case eraseRight
    case homeCursor
    case clearScreen
    case queryCursorLocation
    case saveCursor
    case restoreCursor
    case cursorForward(Int) // (columns)
    case cursorBackward(Int) // (columns)
    case termColor(Int, Bool) // (color, bold)
    case termColor256(Int) // (color)
    case originTermColor
    case cursorUp(Int) // (lines)
    case cursorDown(Int) // (lines)
    case cursorUpHome(Int) // (lines)
    case cursorDownHome(Int) // (lines)
    case eraseCursorRow
    case scrollUp(Int) // (lines)
    case scrollDown(Int) // (lines)
    case cursorDownMayScroll
    case cursorUpMayScroll
    case cursorToColumn(Int) // column
    
    /// references:
    /// https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797
    /// https://notes.burke.libbey.me/ansi-escape-codes/
    /// https://www.wiki.robotz.com/index.php/ANSI_and_VT100_Terminal_Control_Escape_Sequences
    var escaped: String {
        let code: String
        switch self {
        case .eraseRight: code = "[0K"
        case .homeCursor: code = "[H"
        case .clearScreen: code = "[2J"
        case .queryCursorLocation: code = "[6n"
        case .saveCursor: code = "7"
        case .restoreCursor: code = "8"
        case let .cursorForward(cs):
            code = "[\(cs)C"
        case let .cursorBackward(cs):
            code = "[\(cs)D"
        case let .termColor(color, bold):
            code = "[\(bold ? 1 : 0);\(color)m"
        case let .termColor256(color):
            code = "[38;5;\(color)m"
        case .originTermColor: code = "[0m"
        case let .cursorUp(ls):
            code = "[\(ls)A"
        case let .cursorDown(ls):
            code = "[\(ls)B"
        case let .cursorUpHome(ls):
            code = "[\(ls)F"
        case let .cursorDownHome(ls):
            code = "[\(ls)E"
        case .eraseCursorRow:
            code = "[2K"
        case let .scrollUp(ls):
            code = "[\(ls)S"
        case let .scrollDown(ls):
            code = "[\(ls)T"
        case .cursorDownMayScroll:
            code = "D"
        case .cursorUpMayScroll:
            code = "M"
        case let .cursorToColumn(c):
            code = "[\(c)G"
        }
        
        return "\u{001B}\(code)"
    }
}

public extension String {
    init(ansicode: AnsiCode) {
        self = ansicode.escaped
    }
    
    private func colorized(with ac: AnsiCode) -> String {
        return ac.escaped + self + AnsiCode.originTermColor.escaped
    }
    
    func termColorized(_ color: Int, bold: Bool = false) -> String {
        return self.colorized(with: .termColor(color, bold))
    }
    
    func term256Colorized(_ color: Int) -> String {
        return self.colorized(with: .termColor256(color))
    }
    
    func restoreCursorAfterwards() -> String {
        return AnsiCode.saveCursor.escaped + self + AnsiCode.restoreCursor.escaped
    }
}

public enum LineReaderException: Error {
    case error(String)
    case eof
    case interrupt
    case completion(Completion)
}

public class LineReader {
    let input: FileDescriptor
    let output: FileDescriptor
    let history = LineHistory()
    var oldCursorLoc: Int = 0
    var escapingState: EscapingState?
    var inputFileHandle: FileHandle?
    
    typealias HintCallback = (String) -> (String?, AnsiCode?)
    var hintCallback: HintCallback?
    
    typealias CompletionCallback = (String) -> (Completion, String?)
    var completionCallback: CompletionCallback?
    var keptLineState: LineState?
    
    // for subline
    typealias SublineCallback = (LineState) -> String?
    var sublineCallback: SublineCallback?
    private var numSublineRowsShown = 0
    
    // for hint items
    private var hintItems = HintItems()
    
    init(input: FileDescriptor, output: FileDescriptor) {
        self.input = input
        self.output = output
    }
    
    deinit {
        if let fh = self.inputFileHandle {
            fh.readabilityHandler = nil
            self.inputFileHandle = nil
        }
    }
}

private extension Int {
    var cursorForwardAnsiCode: String {
        return self > 0 ? AnsiCode.cursorForward(self).escaped : ""
    }
    
    var cursorBackwardAnsiCode: String {
        return self > 0 ? AnsiCode.cursorBackward(self).escaped : ""
    }
}

extension CmdLineTokenizer.Delimiter {
    private var hintColorEnvName: String {
        let ret: String
        switch self {
        case .pipe, .pipeErrRedi: ret = .envInvalidPipeDelimiter
        case .command: ret = .envInvalidCommandSeparator
        }
        
        return ret
    }
    
    var hintColor: Int {
        return self.hintColorEnvName.getEnvIntValue() ?? 0
    }
}

extension LineReader {
    struct HintItem {
        let index: String.Index
        let color: Int
    }
    
    struct HintItems {
        var beforeCursor: [HintItem] = []
        var sinceCursor: [HintItem] = []
    }
    
    private func updateHintItems(with lineState: LineState) {
        var beforeCursor = [HintItem]()
        var sinceCursor = [HintItem]()
        if let result = try? CmdLineTokenizer(line: lineState.buffer).tokenize() {
            let cursor = lineState.location
            // hint items for invalid delimiters
            let line = lineState.buffer
            for d in result.invalidDelimiters() {
                var index = d.index
                let color = d.delimiter.hintColor
                for i in 0..<d.count {
                    index = line.index(index, offsetBy: i)
                    let item = HintItem(index: index, color: color)
                    if index < cursor {
                        beforeCursor.append(item)
                    } else {
                        sinceCursor.append(item)
                    }
                }
            }
            // hint item for unfinished quote
            // it is for sure after all the invalid delimiters
            if let ufq = result.unfinished {
                let index = ufq.startAt
                let color = Env.getIntValue(for: .envUnfinishedQuoteHintColor) ?? 0
                let item = HintItem(index: index, color: color)
                if index < cursor {
                    beforeCursor.append(item)
                } else {
                    sinceCursor.append(item)
                }
            }
        }
        
        self.hintItems.beforeCursor = beforeCursor
        self.hintItems.sinceCursor = sinceCursor
    }
    
    /// have a chance to manipulate the input before the cursor
    /// before calling updateCursor(...)
    ///
    /// return the changed (or the origin otherwise) string before cursor
    private func updateBufferBeforeCursor(_ lineState: LineState) -> String {
        return self.updateBuffer(for: self.hintItems.beforeCursor,
                                 in: lineState.buffer.startIndex..<lineState.location,
                                 with: lineState)
    }
    
    /// have a chance to manipulate the input after the cursor
    /// before calling write to the output
    private func updateBufferSinceCursor(_ lineState: LineState) -> String {
        return self.updateBuffer(for: self.hintItems.sinceCursor,
                                 in: lineState.location..<lineState.buffer.endIndex,
                                 with: lineState)
    }
    
    private func updateBuffer(for hintItems: [HintItem],
                              in range: Range<String.Index>,
                              with lineState: LineState) -> String {
        let ret: String
        if hintItems.isEmpty {
            ret = String(lineState.buffer[range])
        } else {
            let buf = lineState.buffer
            var new = ""
            var startIdx = range.lowerBound
            for item in hintItems {
                let hintIdx = item.index
                new += String(buf[startIdx..<hintIdx]) + String(buf[hintIdx]).term256Colorized(item.color)
                startIdx = buf.index(after: hintIdx)
            }
            new += String(buf[startIdx..<range.upperBound])
            ret = new
        }
        
        return ret
    }
}

extension LineReader {
    typealias LineStateTask = (LineState) -> Bool
    
    func refresh(_ lineState: LineState) throws {
        self.updateHintItems(with: lineState)
        try self.updateCursor(lineState: lineState) {
            self.updateBufferBeforeCursor(lineState) +
            AnsiCode.eraseRight.escaped +
            lineState.widthBeforeCursor.cursorBackwardAnsiCode
        }
    }
    
    func editOrBeep(lineState: LineState, task: LineStateTask) throws {
        if task(lineState) {
            try self.refresh(lineState)
        } else {
            try self.beep()
        }
    }
    
    func insert(string: String, lineState: LineState) throws {
        for char in string {
            lineState.insert(char: char)
        }
        try self.refresh(lineState)
    }
    
    func insert(char: Character, lineState: LineState) throws {
        try self.insert(string: String(char), lineState: lineState)
    }
    
    func deleteChar(lineState: LineState) throws {
        try self.editOrBeep(lineState: lineState) {
            $0.deleteChar()
        }
    }
    
    private func output(string: String) throws {
        if write(self.output, string, string.utf8.count) == -1 {
            throw LineReaderException.error("failed to write to output")
        }
    }
    
    private func output(char: Character) throws {
        try self.output(string: String(char))
    }
    
    private func output(controlChar: ControlChar) throws {
        try self.output(char: controlChar.char)
    }
    
    private func output(ansiCode: AnsiCode) throws {
        try self.output(string: ansiCode.escaped)
    }
    
    private func beep() throws {
        try self.output(controlChar: .bell)
    }
    
    // MARK: - Cursor
    private func recordOldCursorLocation(lineState: LineState) {
        self.oldCursorLoc = lineState.widthBeforeCursor
    }
    
    private func updateCursor(lineState: LineState,
                              task: (() -> String)? = nil) throws {
        var buf = self.oldCursorLoc.cursorBackwardAnsiCode
        if let t = task {
            buf += t()
        }
        buf += lineState.widthBeforeCursor.cursorForwardAnsiCode
        let (possibleHint, backward) = self.hint(for: lineState)
        if let hint = possibleHint {
            buf += hint
        }
        buf += self.updateBufferSinceCursor(lineState)
        buf += (backward + lineState.widthSinceCursor).cursorBackwardAnsiCode
        if let sl = self.sublineCallback?(lineState) {
            // clean existing subline
            buf += self.escCleanShownSubline()
            // record the new number of subline rows
            let numSublineRows = self.numberOfRows(of: sl)
            // pre-take required lines first, may scroll
            for _ in 0..<numSublineRows {
                buf += AnsiCode.cursorDownMayScroll.escaped
            }
            for _ in 0..<numSublineRows {
                buf += AnsiCode.cursorUpMayScroll.escaped
            }
            // display the subline
            buf += (AnsiCode.cursorDownHome(1).escaped + sl).restoreCursorAfterwards()
            // record the new number of sublines
            self.numSublineRowsShown = numSublineRows
        } else if self.numSublineRowsShown > 0 {
            buf += self.escCleanShownSubline()
        }
        if !buf.isEmpty {
            try self.output(string: buf)
        }
    }
    
    /// calculate number of rows for the given sublines string
    /// this is different from number of lines in that one line
    /// may be divided into several rows if it is long enough
    private func numberOfRows(of sublines: String) -> Int {
        let columns = Env.getIntValue(for: "COLUMNS")
        let lines = sublines.split(omittingEmptySubsequences: false) {
            $0.isNewline
        }
        var ret = 0
        for line in lines {
            ret += self.countRows(lineWidth: line.width,
                                  columns: columns)
        }
        
        return ret
    }
    
    private func countRows(lineWidth: Int, columns: Int?) -> Int {
        var ret = 1
        if let cols = columns, lineWidth > cols {
            ret = lineWidth / cols
            if lineWidth % cols > 0 {
                ret += 1
            }
        }
        
        return ret
    }
    
    /// generate escape string for clean shown subline(s)
    private func escCleanShownSubline() -> String {
        var ret = ""
        if self.numSublineRowsShown > 0 {
            var clean = ""
            for _ in 1...self.numSublineRowsShown {
                clean += AnsiCode.cursorDown(1).escaped
                clean += AnsiCode.eraseCursorRow.escaped
            }
            ret = clean.restoreCursorAfterwards()
            self.numSublineRowsShown = 0
        }
        
        return ret
    }
    
    private func cleanShownSubline() {
        do {
            try self.output(string: self.escCleanShownSubline())
        } catch {
            NSLog("failed to clean shown subline: \(error)")
        }
    }
    
    private func updateCursorOrBeep(lineState: LineState, task: LineStateTask) throws {
        if task(lineState) {
            try self.refresh(lineState)
        } else {
            try self.beep()
        }
    }
}

private extension UInt8 {
    var character: Character {
        return Character(UnicodeScalar(self))
    }
}

private extension Character {
    var width: Int {
        return self.unicodeScalars.first.map {
            Int(gCellsCaculator(Int($0.value)))
        } ?? 0
    }
}

extension StringProtocol {
    var width: Int {
        var ret = 0
        for char in self {
            ret += char.width
        }
        
        return ret
    }
}

private extension String {
    static let tab = String(repeatElement(" ", count: 4))
}

public extension LineReader {
    private func readInput() -> String? {
        let len = Int(PIPE_BUF)
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: len)
        defer {
            bytes.deinitialize(count: len)
            bytes.deallocate()
        }
        let readLen = read(self.input, bytes, len)
        let data = Data(bytes: bytes, count: readLen)
        
        return String(data: data, encoding: .utf8)
    }
    
    @discardableResult private func handle(
        controlChar char: ControlChar,
        lineState: LineState) throws -> String? {
        var ret: String?
        switch char {
        case .enter:
            ret = lineState.buffer
        case .c_a:
            try self.updateCursorOrBeep(lineState: lineState) {
                $0.moveHome()
            }
        case .c_e:
            try self.updateCursorOrBeep(lineState: lineState) {
                $0.moveEnd()
            }
        case .c_b:
            try self.updateCursorOrBeep(lineState: lineState) {
                $0.moveBackward()
            }
        case .c_f:
            try self.updateCursorOrBeep(lineState: lineState) {
                $0.moveForward()
            }
        case .c_t:
            try self.updateCursorOrBeep(lineState: lineState) {
                $0.moveBackwardWord()
            }
        case .c_y:
            try self.updateCursorOrBeep(lineState: lineState) {
                $0.moveForwardWord()
            }
        case .c_c:
            throw LineReaderException.interrupt
        case .c_d:
            if !lineState.isAtEnd {
                // if there is char under cursor
                // delete it
                try self.deleteChar(lineState: lineState)
            } else {
                // if line is empty, throw EOF
                // otherwise act like .enter
                if lineState.isEmpty {
                    throw LineReaderException.eof
                } else {
                    ret = lineState.buffer
                }
            }
        case .c_p:
            try self.editOrBeep(lineState: lineState) {
                self.moveToPreviousHisItem(lineState: $0)
            }
        case .c_n:
            try self.editOrBeep(lineState: lineState) {
                self.moveToNextHisItem(lineState: $0)
            }
        case .c_u:
            try self.editOrBeep(lineState: lineState) {
                $0.deleteToHome()
            }
        case .c_k:
            try self.editOrBeep(lineState: lineState) {
                $0.deleteToEnd()
            }
        case .c_w:
            try self.editOrBeep(lineState: lineState) {
                $0.deletePreviousWord()
            }
        case .c_h, .backspace:
            try self.editOrBeep(lineState: lineState) {
                $0.backspace()
            }
        default:
            try self.insert(char: char.rawValue.character,
                            lineState: lineState)
        }
        
        return ret
    }
    
    private func handle(asciiChar char: UInt8,
                        lineState: LineState) throws -> String? {
        var ret: String?
        if let cc = ControlChar(rawValue: char) {
            ret = try self.handle(controlChar: cc,
                                  lineState: lineState)
        } else {
            try self.insert(char: char.character, lineState: lineState)
        }
        
        return ret
    }
    
    private func handleEscaping(_ state: EscapingState,
                                lineState: LineState) throws -> Bool {
        // return true if handled, otherwise false
        // reset self.escapingState to nil if not
        // expecting the next char
        var handled = true
        var equivalent: ControlChar?
        switch state.order {
        case 1: // handle the first follow up char
            let char = state.currentChar
            if char != "[" && char != "O" {
                handled = false
                self.escapingState = nil
            }
        case 2: // handle the second follow up char
            var expectNext = false
            switch state.char(at: 1) {
            case "[":
                switch state.currentChar {
                case "A": // ^[[A: up arrow
                    equivalent = .c_p
                case "B": // ^[[B: down arrow
                    equivalent = .c_n
                case "C": // ^[[C: right arrow
                    equivalent = .c_f
                case "D": // ^[[D: left arrow
                    equivalent = .c_b
                case "H": // ^[[H: home?
                    equivalent = .c_a
                case "F": // ^[[F:
                    equivalent = .c_e
                case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                    expectNext = true
                default:
                    break
                }
            case "O":
                switch state.currentChar {
                case "H": // ^[OH
                    equivalent = .c_a
                case "F": // ^[OF
                    equivalent = .c_e
                default:
                    break
                }
            default:
                break
            }
            if !expectNext {
                self.escapingState = nil
            }
        case 3: // handle the third follow up char
            switch state.currentChar {
            case "~":
                switch state.char(at: 2) {
                case "1", "7": // ^[[1~ or ^[[7~
                    equivalent = .c_a
                case "3": // ^[[3~
                    try self.deleteChar(lineState: lineState)
                case "4": // ^[[4~
                    equivalent = .c_e
                default:
                    break
                }
            default:
                break
            }
            self.escapingState = nil
        default: // handle no more
            handled = false
        }
        if let eq = equivalent {
            try self.handle(controlChar: eq, lineState: lineState)
        }
        
        return handled
    }
    
    private func handle(input: String,
                        lineState: LineState) throws -> String? {
//        NSLog("\(input)")
        var ret: String?
        var err: Error?
        self.handle(input: input, lineState: lineState) { (line, error) in
            ret = line
            err = error
        }
        try err.map { throw $0 }
        
        return ret
    }
    
    private func handleCompletion(_ lineState: LineState) throws {
        if let cb = self.completionCallback {
            let bbc = lineState.bufferBeforeCursor
            let bsc = lineState.bufferSinceCursor
            let (c, new) = cb(bbc)
            let old = c.info.pattern
            let cands = c.candidates
            
            if cands.count == 1 {
                // don't append space if not at end
                // or is dir
                let space = (bsc.isEmpty && !cands[0].hasSuffix("/")) ? " " : ""
                let sub = String(bbc.dropLast(old.count)) +
                    c.info.complete(cands[0]) + space + bsc
                // complete it if only one candidate
                try self.editOrBeep(lineState: lineState) {
                    $0.replaceBuffer(with: sub) &&
                        $0.moveBackward(for: bsc.count)
                }
            } else if !cands.isEmpty {
                var sub = bbc
                if let n = new {
                    sub = sub.dropLast(old.count) + n
                }
                sub += bsc
                try self.editOrBeep(lineState: lineState) {
                    $0.replaceBuffer(with: sub) &&
                        $0.moveBackward(for: bsc.count)
                }
                self.keptLineState = lineState
                // clean possible shown subline
                self.cleanShownSubline()
                // notify completion handling
                throw LineReaderException.completion(c)
            } // ignore empty candidates
        } else {
            // convert a tab into 4 spaces otherwise
            try self.insert(string: .tab,
                            lineState: lineState)
        }
    }
    
    typealias LineConsumer = (String?, Error?) -> Void
    private func handle(input: String,
                        lineState: LineState,
                        consumer: LineConsumer) {
        do {
            for char in input {
                self.recordOldCursorLocation(lineState: lineState)
                if let ascii = char.asciiValue {
                    // is it escaping?
                    if ascii == ControlChar.esc.rawValue {
                        self.escapingState = EscapingState()
                        continue
                    }
                    if let eState = self.escapingState {
                        eState.append(char)
                        if try self.handleEscaping(eState, lineState: lineState) {
                            continue
                        }
                    }
                    // completion
                    if ascii == ControlChar.tab.rawValue {
                        try self.handleCompletion(lineState)
                        continue
                    }
                    if let rv = try handle(asciiChar: ascii, lineState: lineState) {
                        // clean possible subline first
                        self.cleanShownSubline()
                        // add it to history
                        self.addToHistory(rv)
                        // let the shell handle the input line
                        consumer(rv, nil)
                        lineState.reset()
                        return
                    }
                } else {
                    try self.insert(char: char, lineState: lineState)
                }
            }
            // handle probably hanging esc
            if let eState = self.escapingState {
                if !eState.hasChars {
                    try self.editOrBeep(lineState: lineState) {
                        self.resetToHisCache(lineState: $0)
                    }
                }
                self.escapingState = nil
            }
        } catch {
            consumer(nil, error)
        }
    }
    
    private func createLineState() throws -> LineState {
        var ret: LineState?
        if let kls = self.keptLineState {
            ret = kls
            self.oldCursorLoc = 0
            try self.refresh(kls)
            self.keptLineState = nil
        }
        
        return ret ?? LineState()
    }
    
    func readline() throws -> String {
        let state = try self.createLineState()
        while true {
            guard let input = self.readInput() else { continue }
            if let rv = try self.handle(input: input, lineState: state) {
                return rv
            }
        }
    }
    
    func readlineAsynchronously(_ consumer: @escaping LineConsumer) {
        let state: LineState
        do {
            state = try self.createLineState()
        } catch {
            consumer(nil, error)
            return
        }
        self.inputFileHandle = FileHandle(fileDescriptor: self.input,
                                          closeOnDealloc: false)
        self.inputFileHandle?.readabilityHandler = {
            guard let input = String(data: $0.availableData, encoding: .utf8),
                !input.isEmpty else { return }
            self.handle(input: input, lineState: state, consumer: consumer)
        }
    }
}

extension LineReader {
    // MARK: - Hints
    private func hint(for lineState: LineState) -> (String?, Int) {
        guard let cb = self.hintCallback,
            lineState.charAtCursor?.isWhitespace ?? true
            else { return (nil, 0) }
        let (hStr, cCode) = cb(lineState.bufferBeforeCursor)
        var ret: String?
        var backward = 0
        if let h = hStr {
            // append the hint
            // default color of hint text is "grey54 (245)"
            var r = ""
            r += (cCode ?? AnsiCode.termColor256(245)).escaped
            r += h + AnsiCode.originTermColor.escaped
            ret = r
            backward = h.width
        }
        
        return (ret, backward)
    }
}

extension LineReader {
    // MARK: - History
    private func moveToPreviousHisItem(lineState: LineState) -> Bool {
        return self.history.goPrevious(with: lineState)
    }
    
    private func moveToNextHisItem(lineState: LineState) -> Bool {
        return self.history.goNext(with: lineState)
    }
    
    private func resetToHisCache(lineState: LineState) -> Bool {
        return self.history.resetToCache(with: lineState)
    }
    
    private func addToHistory(_ line: String) {
        self.history.add(item: line)
    }
    
    func currentHistoryList() -> String {
        return self.history.list()
    }
    
    func loadHistory(from path: String) throws {
        try self.history.load(from: URL(fileURLWithPath: path))
    }
    
    func saveHistory(to path: String) throws {
        try self.history.save(to: URL(fileURLWithPath: path))
    }
}

internal class EscapingState {
    var chars = [Character]()
    var order: Int {
        return self.chars.count
    }
    
    var hasChars: Bool {
        return self.chars.count > 0
    }
    
    func append(_ char: Character) {
        self.chars.append(char)
    }
    
    func char(at order: Int) -> Character {
        return self.chars[order - 1]
    }
    
    var currentChar: Character {
        return self.char(at: self.order)
    }
}

internal class LineState {
    var buffer = ""
    var location: String.Index
    
    init() {
        self.location = self.buffer.endIndex
    }
}

internal extension LineState {
    private enum LocationUpdateAction {
        case forward
        case backward
        case home
        case end
        case forwardWhile((Character) -> Bool)
        case backwardWhile((Character) -> Bool)
    }
    
    var isAtHome: Bool {
        return self.location == self.buffer.startIndex
    }
    
    var isAtEnd: Bool {
        return self.location == self.buffer.endIndex
    }
    
    var isEmpty: Bool {
        return self.buffer.isEmpty
    }
    
    var bufferBeforeCursor: String {
        guard !self.isEmpty && !self.isAtHome else { return "" }
        return String(self.buffer[..<self.location])
    }
    
    var bufferSinceCursor: String {
        guard !self.isEmpty && !self.isAtEnd else { return "" }
        return String(self.buffer[self.location...])
    }
    
    var widthBeforeCursor: Int {
        return self.bufferBeforeCursor.width
    }
    
    var widthSinceCursor: Int {
        return self.bufferSinceCursor.width
    }
    
    var charAtCursor: Character? {
        guard !self.isEmpty && !self.isAtEnd else { return nil }
        return self.buffer[self.location]
    }
    
    private func makeLocation(_ action: LocationUpdateAction) {
        switch action {
        case .forward:
            self.location = self.buffer.index(after: self.location)
        case .backward:
            self.location = self.buffer.index(before: self.location)
        case .home:
            self.location = self.buffer.startIndex
        case .end:
            self.location = self.buffer.endIndex
        case let .forwardWhile(condition):
            for c in self.buffer[self.location...] {
                if !self.isAtEnd && condition(c) {
                    self.location = self.buffer.index(after: self.location)
                } else {
                    break
                }
            }
        case let .backwardWhile(condition):
            for c in self.buffer[..<self.location].reversed() {
                if !self.isAtHome && condition(c) {
                    self.location = self.buffer.index(before: self.location)
                } else {
                    break
                }
            }
        }
    }
    
    private func removeAtLocation() {
        self.buffer.remove(at: self.location)
    }
    
    func insert(char: Character) {
        let wasAtEnd = self.isAtEnd
        self.buffer.insert(char, at: self.location)
        self.makeLocation(.forward)
        if wasAtEnd {
            self.makeLocation(.end)
        }
    }
    
    func backspace() -> Bool {
        guard !self.isAtHome else { return false }
        self.makeLocation(.backward)
        self.removeAtLocation()
        
        return true
    }
    
    func moveBackward() -> Bool {
        guard !self.isAtHome else { return false }
        self.makeLocation(.backward)
        
        return true
    }
    
    func moveBackward(for steps: Int) -> Bool {
        var ret = true
        for _ in 0..<steps {
            ret = ret && self.moveBackward()
        }
        
        return ret
    }
    
    func moveBackwardWord() -> Bool {
        let oldLocation = self.location
        // locate backwardly the first non-whitespace char
        self.makeLocation(.backwardWhile({ $0.isWhitespace }))
        // then locate backwardly the first whitespace char
        self.makeLocation(.backwardWhile({ !$0.isWhitespace }))
        
        return self.buffer.distance(from: oldLocation, to: self.location) != 0
    }
    
    func moveForward() -> Bool {
        guard !self.isAtEnd else { return false }
        self.makeLocation(.forward)
        
        return true
    }
    
    func moveForwardWord() -> Bool {
        let oldLocation = self.location
        // locate forwardly the first non-whitespace char
        self.makeLocation(.forwardWhile({ $0.isWhitespace }))
        // then locate forwardly the first whitespace char
        self.makeLocation(.forwardWhile({ !$0.isWhitespace }))
        
        return self.buffer.distance(from: oldLocation, to: self.location) != 0
    }
    
    func moveHome() -> Bool {
        guard !self.isAtHome else { return false }
        self.makeLocation(.home)
        
        return true
    }
    
    func moveEnd() -> Bool {
        guard !self.isAtEnd else { return false }
        self.makeLocation(.end)
        
        return true
    }
    
    func replaceBuffer(with line: String) -> Bool {
        self.buffer = line
        
        return self.moveEnd()
    }
    
    func deleteChar() -> Bool {
        guard !self.isEmpty && !self.isAtEnd else { return false }
        self.removeAtLocation()
        
        return true
    }
    
    func deletePreviousWord() -> Bool {
        let oldLocation = self.location
        let succeeded = self.moveBackwardWord()
        if succeeded {
            self.buffer.removeSubrange(self.location..<oldLocation)
        }
        
        return succeeded
    }
    
    func deleteToHome() -> Bool {
        guard !self.isAtHome && !self.isEmpty else { return false }
        self.buffer.removeSubrange(..<self.location)
        self.makeLocation(.home)
        
        return true
    }
    
    func deleteToEnd() -> Bool {
        guard !self.isAtEnd && !self.isEmpty else { return false }
        self.buffer.removeSubrange(self.location...)
        
        return true
    }
    
    func reset() {
        self.buffer = ""
        self.location = self.buffer.endIndex
    }
}
