import CutlineMCP
import Foundation

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--worker" {
    exit(await AnalysisWorker.run(bundle: args[2]))
}
await MCPServer(runsJobsInWorker: true).run()
