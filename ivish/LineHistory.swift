//
//  LineHistory.swift
//  ivish
//
//  Created by Terry Chou on 1/13/20.
//  Copyright © 2020 Boogaloo. All rights reserved.
//

import Foundation


internal class LineHistory {
    private var currentIndex: Int = -1
    private var lineCache: String?
    var items = [String]()
    var maxItemNum = 100 {
        didSet {
            self.tuneItemNum()
        }
    }
}

internal extension LineHistory {
    private func tuneItemNum() {
        let overflow = self.items.count - self.maxItemNum
        if overflow > 0 {
            self.items.removeFirst(overflow)
        }
    }
    
    private func pointToLineState() {
        self.currentIndex = self.items.count
    }
    
    private var isPointingAtLineState: Bool {
        return self.currentIndex == self.items.count
    }
}

internal extension LineHistory {
    var isEmpty: Bool {
        return self.items.isEmpty
    }
    
    func add(item: String) {
        self.items.append(item)
        self.tuneItemNum()
        self.pointToLineState()
    }
    
    func goPrevious(with state: LineState) -> Bool {
        guard !self.isEmpty else { return false }
        var succeeded = true
        if self.isPointingAtLineState || self.currentIndex == -1 {
            self.currentIndex = self.items.count - 1
            self.lineCache = state.buffer
        } else if self.currentIndex == 0 {
            // already at the earliest
            succeeded = false
        } else {
            self.currentIndex -= 1
        }
        if succeeded {
            succeeded = succeeded &&
                state.replaceBuffer(
                    with: self.items[self.currentIndex])
        }
        
        return succeeded
    }
    
    func goNext(with state: LineState) -> Bool {
        guard !self.isEmpty else { return false }
        let succeeded: Bool
        if self.isPointingAtLineState || self.currentIndex == -1 {
            succeeded = false
        } else if self.currentIndex == self.items.count - 1 {
            succeeded = self.resetToCache(with: state)
        } else {
            self.currentIndex += 1
            let line = self.items[self.currentIndex]
            succeeded = state.replaceBuffer(with: line)
        }
        
        return succeeded
    }
    
    func resetToCache(with state: LineState) -> Bool {
        guard let l = self.lineCache else { return false }
        self.pointToLineState()
        self.lineCache = nil
        
        return state.replaceBuffer(with: l)
    }
}

private extension String {
    func leftPadding(toLength: Int, withPad pad: Character) -> String {
        let numToPad = toLength - self.count
        let ret: String
        if numToPad > 0 {
            ret = String(repeatElement(pad, count: numToPad)) + self
        } else {
            ret = String(self.suffix(toLength))
        }
        
        return ret
    }
}

internal extension LineHistory {
    func list() -> String {
        // line format: " index  item"
        let len = String(self.items.count).count + 1
        var ret = ""
        for (i, item) in self.items.enumerated() {
            let iStr = "\(i + 1)".leftPadding(toLength: len,
                                              withPad: " ")
            ret += "\(iStr)  \(item)\n"
        }
        
        return ret
    }
    
    func load(from url: URL) throws {
        let persisted = try String(contentsOf: url, encoding: .utf8)
        persisted.split(separator: "\n").forEach {
            self.items.append(String($0))
        }
        self.tuneItemNum()
        self.pointToLineState()
    }
    
    func save(to url: URL) throws {
        let toBePersisted = self.items.joined(separator: "\n")
        try toBePersisted.write(to: url,
                                atomically: true,
                                encoding: .utf8)
    }
}
