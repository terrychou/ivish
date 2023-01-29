//
//  InterruptHandler.swift
//  ivish
//
//  Created by Terry Chou on 1/14/20.
//  Copyright © 2020 Boogaloo. All rights reserved.
//

import Foundation


public class InterruptHandler {
    let cdb: CommandDatabase
    
    enum Action: String {
        case kill = "thread_kill"
        case cancel = "thread_cancel"
        case eof = "end_of_file"
        case handler = "handler_func"
        case handlerNl = "handler_func_nl"
    }
    
    init(cmdDatabase: CommandDatabase) {
        self.cdb = cmdDatabase
    }
}

public extension InterruptHandler {
    func handle(cmdName: String,
                output: (String) -> Void,
                tid: @autoclosure () -> pthread_t,
                eof: () -> Void) {
        guard let aName = self.cdb.property(.intAction, of: cmdName),
            let action = Action(rawValue: aName) else {
                NSLog("failed to get int action for '\(cmdName)'")
                if let sa = SignalAction(signal: SIGINT) {
                    sa.handle()
                } else {
                    pthread_cancel(tid())
                }
                return
        }
        switch action {
        case .kill:
            pthread_kill(tid(), SIGINT)
        case .handler, .handlerNl:
            SignalAction(signal: SIGINT)?.handle()
            if action == .handlerNl {
                output("\n")
            }
        case .cancel:
            pthread_cancel(tid())
        case .eof:
            eof()
        }
    }
}

public class SignalAction {
    let signal: Int32
    let handler: (Int32) -> Void
    
    init?(signal: Int32) {
        let sa = UnsafeMutablePointer<sigaction>.allocate(capacity: 1)
        defer {
            sa.deinitialize(count: 1)
            sa.deallocate()
        }
        if sigaction(signal, nil, sa) >= 0,
            let h = sa.pointee.__sigaction_u.__sa_handler {
            self.signal = signal
            self.handler = h
        } else {
            return nil
        }
    }
    
    func handle() {
        self.handler(self.signal)
    }
}

public class CommandDatabase {
    let content: [String: Any]
    
    enum CommandDatabaseError: Error {
        case invalidFormat
    }
    
    enum CommandProperty: String {
        case intAction = "intaction"
        case termMode = "termmode"
        
        var name: String {
            return self.rawValue
        }
    }
    
    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url, options: [])
        let pList = try PropertyListSerialization.propertyList(
            from: data,
            options: .mutableContainers,
            format: nil)
        if let c = pList as? [String: Any] {
            self.content = c
        } else {
            throw CommandDatabaseError.invalidFormat
        }
    }
    
    private typealias CommandInfo = [String: String]
    private func info(for cmd: String) -> CommandInfo? {
        return self.content[cmd] as? CommandInfo
    }
    
    func property(_ p: CommandProperty, of cmd: String) -> String? {
        return self.info(for: cmd)?[p.name]
    }
}
