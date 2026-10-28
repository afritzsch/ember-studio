import Foundation
import Synchronization

/// MODEL-006: maps wire `type` strings to command types, and decodes the control protocol's
/// `{"type": …, …}` JSON (13).
public enum CommandRegistry {
    /// Every command type DAWModel defines. Add new commands here.
    public static let builtIn: [any Command.Type] = [
        CompositeCommand.self,
        RenameTrack.self,
        // T-022: routing (MODEL-005, routing subset)
        AddTrack.self,
        RemoveTrack.self,
        RestoreTrack.self,
        MoveTrack.self,
        SetTrackOutput.self,
        AddBus.self,
        RemoveBus.self,
        RestoreBus.self,
        AddSend.self,
        RemoveSend.self,
        RestoreSend.self,
        SetSendLevel.self,
        SetSendTap.self,
        SetSidechain.self,
        SetParam.self,
    ]

    private static let table = Mutex<[String: any Command.Type]>(
        Dictionary(uniqueKeysWithValues: builtIn.map { ($0.type, $0) }))

    /// All registered command types, sorted by `type` (for CTL-024's schema listing).
    public static var registered: [any Command.Type] {
        table.withLock { $0.values.sorted { $0.type < $1.type } }
    }

    public static func commandType(named type: String) -> (any Command.Type)? {
        table.withLock { $0[type] }
    }

    /// Adds a command type defined outside DAWModel (tests, tools). Registering the same type again
    /// is a no-op; a different type with a taken `type` string is a programming error.
    public static func register(_ commandType: any Command.Type) {
        table.withLock { table in
            if let existing = table[commandType.type] {
                precondition(existing == commandType, "command type \"\(commandType.type)\" is already registered")
                return
            }
            table[commandType.type] = commandType
        }
    }

    public static func decode(_ json: Data) throws(DAWError) -> any Command {
        do {
            return try JSONDecoder().decode(AnyCommand.self, from: json).base
        } catch let error as DAWError {
            throw error
        } catch {
            throw .malformedCommand(String(describing: error))
        }
    }

    /// The wire form, with sorted keys so equal commands encode to equal bytes.
    public static func encode(_ command: any Command) throws(DAWError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(AnyCommand(command))
        } catch {
            throw .malformedCommand(String(describing: error))
        }
    }
}
