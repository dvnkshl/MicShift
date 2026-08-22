import AppKit
import Foundation

@main
enum DJIMicAutoMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--diagnose-audio") {
            do {
                print(try AudioDeviceManager().diagnosticReport())
                exit(EXIT_SUCCESS)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
