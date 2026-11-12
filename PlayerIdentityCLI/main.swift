import Foundation

// §34 `playeridentityctl` entry point. Standard input is only read for the `update --install` y/N answer on a terminal (§51).
let result = await CLIRunner.run(arguments: Array(CommandLine.arguments.dropFirst()), context: .live())
FileHandle.standardOutput.write(Data(result.stdout.utf8))
FileHandle.standardError.write(Data(result.stderr.utf8))
exit(result.exitCode)
