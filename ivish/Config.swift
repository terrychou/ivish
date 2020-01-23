//
//  Config.swift
//  ivish
//
//  Created by Terry Chou on 1/14/20.
//  Copyright © 2020 Boogaloo. All rights reserved.
//

import Foundation


internal class Config {
    var table = [String: String]()
    
    subscript(_ name: String) -> String? {
        get {
            return self.table[name]
        }
        set {
            self.table[name] = newValue
        }
    }
}

internal extension Config {
    typealias Importer = (String) -> String?
    private func `import`(for names: [String],
                          with importer: Importer) {
        for name in names {
            if let value = importer(name) {
                self[name] = value
            }
        }
    }
    
    func importFromEnv(for names: [String]) {
        self.import(for: names) {
            getenv($0).map { String(cString: $0) }
        }
    }
}

internal enum ShellEnvVar: String, CaseIterable {
    case cmdDatabase = "IVISH_CMD_DB"
    case columns = "COLUMNS"
    case historyPath = "IVISH_HISTORY_FILE"
    
    var name: String {
        return self.rawValue
    }
}

internal extension Config {
    subscript(_ envVar: ShellEnvVar) -> String? {
        get {
            return self[envVar.name]
        }
        set {
            self[envVar.name] = newValue
        }
    }
}
