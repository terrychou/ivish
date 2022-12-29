//
//  CmdLineTokenizer.swift
//  ivish
//
//  Created by Terry Chou on 2022/12/15.
//  Copyright © 2022 Boogaloo. All rights reserved.
//

import Foundation

final class CmdLineTokenizer {
    typealias Element = String.Element
    typealias Handler = (Element, CmdLineTokenizer) throws -> Bool
    let line: String
    var rest = ""
    var accum: String?
    var escaping: Escaping?
    var results: [String]?
    var isSubescaping = false
    var unfinishedEscape: EscapeInfo?

    init(line: String) {
        self.line = line
    }
}

extension CmdLineTokenizer {
    enum Escaping: String {
        case singleQuote = "'"
        case doubleQuote = "\""
        case backslash = "\\"

        var handler: Handler {
            let ret: Handler
            switch self {
            case .singleQuote: ret = self.singleQuoteHandle
            case .doubleQuote: ret = self.doubleQuoteHandle
            case .backslash: ret = self.backslashHandle
            }

            return ret
        }

        private func singleQuoteHandle(
            elem: Element,
            tokenizer: CmdLineTokenizer) throws -> Bool {
            var done = false
            if elem == "'" {
                // done escaping
                done = true
            } else {
                tokenizer.accum?.append(elem)
            }

            return done
        }

        private func doubleQuoteHandle(
            elem: Element,
            tokenizer: CmdLineTokenizer) throws -> Bool {
            var done = false
            if elem == "\"" || elem == "\\" {
                if tokenizer.isSubescaping {
                    // escaped double quote
                    tokenizer.accum!.append(elem)
                    tokenizer.isSubescaping = false
                } else {
                    if elem == "\"" {
                        // done escaping
                        done = true
                    } else {
                        // mark escaping for next char
                        tokenizer.isSubescaping = true
                    }
                }
            } else {
                if tokenizer.isSubescaping {
                    tokenizer.accum?.append("\\")
                    tokenizer.isSubescaping = false
                }
                tokenizer.accum?.append(elem)
            }

            return done
        }

        private func backslashHandle(
            elem: Element,
            tokenizer: CmdLineTokenizer) throws -> Bool {
            tokenizer.accum?.append(elem)

            return true
        }
    }

//    enum ParseError: Error, Equatable {
//        case unfinished(String)
//    }

    private func harvest() {
        guard let a = self.accum else { return }
        self.results?.append(a)
        self.accum = nil
    }

    private func run(count: Int) throws {
        self.results = []
        var index = self.line.startIndex
        var escapeAt = self.line.startIndex
        var lastTokenStartAt: String.Index?
        while index != self.line.endIndex {
            let element = self.line[index]
            var startEscaping = false
            let wasNotToken = self.accum == nil
            try self.handle(element: element,
                            startEscaping: &startEscaping)
            let isTokenStart = wasNotToken && self.accum != nil
            if startEscaping {
                escapeAt = index
            }
            if isTokenStart {
                lastTokenStartAt = index
            }
            if count > 0 && self.results!.count == count {
                // collected enough
                break
            }
            index = self.line.index(after: index)
        }
        var restStartAt: String.Index?
        if let esc = self.escaping {
            // unfinished token
            self.unfinishedEscape = .init(startAt: escapeAt,
                                          escape: esc)
            restStartAt = lastTokenStartAt
        } else {
            self.harvest()
        }
        self.rest = String(self.line[(restStartAt ?? index)...])
//        if self.escaping == nil {
//            // do the possible last harvest
//            self.harvest()
//        }
//        if let esc = self.escaping {
//            // encounter unfinished token
//            if count > 0 && self.results!.count == count {
//                // collected enough, no exception thrown
//                self.rest = self.accum ?? ""
//            } else {
//                throw ParseError.unfinished(esc.rawValue)
//            }
//        }
//        self.rest = String(self.line[index...])
//        if count > 0 && self.results!.count == count {
//
//        }
//        if let esc = self.escaping {
//            // unfinished escaping
//            throw ParseError.unfinished(esc.rawValue)
//        } else {
//            self.harvest()
//        }
    }

    private func prepareAccum() {
        if self.accum == nil {
            self.accum = ""
        }
    }

    private func handle(element: Element,
                        startEscaping: inout Bool) throws {
        if let esc = self.escaping {
            // escaping
            if try esc.handler(element, self) {
                // done current escaping
                self.escaping = nil
            }
        } else if let newEsc = Escaping(rawValue: String(element)) {
            // start a new escaping
            self.escaping = newEsc
            startEscaping = true
            self.prepareAccum()
        } else if element.isWhitespace {
            // skip whitespace and harvest possible token
            self.harvest()
        } else {
            // accumulate others
            self.prepareAccum()
            self.accum!.append(element)
        }
    }
    
    struct EscapeInfo {
        let startAt: String.Index
        let escape: Escaping
    }
    
    struct Result {
        let tokens: [String]
        let rest: String
        let unfinished: EscapeInfo?
        
        func token(at index: Int) -> String? {
            var ret: String?
            if self.tokens.indices.contains(index) {
                ret = self.tokens[index]
            }
            
            return ret
        }
    }

    /// tokenize the line provided in initialization
    /// if a greater-than-zero `count` is given
    /// only try to tokenize the first `count` tokens
    func tokenize(count: Int=0) throws -> Result {
        try self.run(count: count)
        
        return .init(tokens: self.results ?? [],
                     rest: self.rest,
                     unfinished: self.unfinishedEscape)
    }
}
