import Foundation

let cliArgs = CommandLine.arguments
if cliArgs.count > 1, ["rules", "terminals", "plugins", "folders"].contains(cliArgs[1]) {
  exit(ActionsCLI.run(Array(cliArgs.dropFirst())))
}
MaccyApp.main()
