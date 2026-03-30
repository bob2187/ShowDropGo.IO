import Foundation
import ScreenCaptureKit

// Disable stdout buffering so frames reach the Go server immediately.
setbuf(stdout, nil)

guard #available(macOS 13.0, *) else {
    fputs("sdg-rdp-capture requires macOS 13+\n", stderr)
    exit(1)
}

let manager = CaptureManager()

// Start capture on a Task so we can use async/await.
Task {
    do {
        try await manager.start()
    } catch {
        fputs("capture start failed: \(error)\n", stderr)
        exit(1)
    }
}

// Read input events from stdin (JSON lines) on a background thread.
DispatchQueue.global(qos: .userInteractive).async {
    var buffer = Data()
    let stdin = FileHandle.standardInput

    while true {
        let chunk = stdin.availableData
        if chunk.isEmpty {
            Thread.sleep(forTimeInterval: 0.005)
            continue
        }
        buffer.append(chunk)

        // Process all complete newline-delimited JSON messages.
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)

            if lineData.isEmpty { continue }
            if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                InputHandler.handle(json)
            }
        }
    }
}

RunLoop.main.run()
