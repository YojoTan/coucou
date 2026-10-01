import Foundation

@main
enum ExtrasParseTests {
    static func main() {
        // Meeting links, wherever the event keeps them.
        precondition(ExtrasParse.meetingLink(in: [nil, "Sala 3", "Únete: https://meet.google.com/abc-defg-hij."])?.absoluteString
                     == "https://meet.google.com/abc-defg-hij", "meet in notes, trailing dot dropped")
        precondition(ExtrasParse.meetingLink(in: ["https://us02web.zoom.us/j/8123456789?pwd=xyz"])?.host == "us02web.zoom.us", "zoom")
        precondition(ExtrasParse.meetingLink(in: ["https://teams.microsoft.com/l/meetup-join/19%3ameeting_x"]) != nil, "teams")
        precondition(ExtrasParse.meetingLink(in: ["https://example.com/meet", "Oficina"]) == nil, "not a call link")

        // What Mochi wears for the weather.
        precondition(ExtrasParse.weatherAccessory(code: 61, temperature: 20, day: true, rainChance: 0) == .umbrella, "raining")
        precondition(ExtrasParse.weatherAccessory(code: 2, temperature: 20, day: true, rainChance: 60) == .umbrella, "rain likely")
        precondition(ExtrasParse.weatherAccessory(code: 3, temperature: 4, day: true, rainChance: 10) == .scarf, "cold")
        precondition(ExtrasParse.weatherAccessory(code: 0, temperature: 28, day: true, rainChance: 0) == .sunglasses, "hot and clear")
        precondition(ExtrasParse.weatherAccessory(code: 0, temperature: 28, day: false, rainChance: 0) == .none, "no sunglasses at night")

        // Custom Mochi command output.
        precondition(ExtrasParse.commandOutput("working: deploying v2\nmore", exitCode: 0) == ("deploying v2", "working"), "prefix")
        precondition(ExtrasParse.commandOutput("ERROR: disk full", exitCode: 0) == ("disk full", "error"), "prefix, any case")
        precondition(ExtrasParse.commandOutput("3 pods running", exitCode: 0) == ("3 pods running", "ok"), "exit 0")
        precondition(ExtrasParse.commandOutput("", exitCode: 2) == ("", "error"), "exit code")
        // Seasonal outfits.
        precondition(ExtrasParse.season(month: 10, day: 20, birthday: nil) == .pumpkin, "late October")
        precondition(ExtrasParse.season(month: 10, day: 1, birthday: nil) == nil, "early October")
        precondition(ExtrasParse.season(month: 12, day: 24, birthday: nil) == .santaHat, "December")
        precondition(ExtrasParse.season(month: 10, day: 20, birthday: "10-20") == .partyHat, "birthday wins")
        precondition(ExtrasParse.season(month: 3, day: 4, birthday: "10-20") == nil, "ordinary day")
        // Claude Code's permission dialog, as Orca reads a terminal's screen.
        let dialog = ["╭──────────────╮", "│ Bash command", "│   git push origin main", "│ Do you want to proceed?",
                      "│ ❯ 1. Yes", "│   2. Yes, and don't ask again for git push commands", "│   3. No, and tell Claude what to do differently (esc)", "╰──────╯"]
        precondition(OrcaParse.showsPermissionDialog(dialog, needsAlways: false), "dialog seen")
        precondition(OrcaParse.showsPermissionDialog(dialog, needsAlways: true), "always offered")
        precondition(!OrcaParse.showsPermissionDialog(dialog.filter { !$0.contains("2. Yes") }, needsAlways: true), "no always option")
        precondition(!OrcaParse.showsPermissionDialog(["> fix the login bug", "  1. Yes I think so"], needsAlways: false), "a chat line isn't a dialog")
        precondition(!OrcaParse.showsPermissionDialog([], needsAlways: false), "empty screen")
        // A tall window: the dialog near the top, forty empty rows under it, colour codes.
        let tall = ["\u{1B}[1m Bash command\u{1B}[0m", "   cd \"/x\" && python3 - <<'PY'", " Do you want to proceed?",
                    " \u{1B}[36m❯ 1. Yes\u{1B}[0m   ", "   2. Yes, and don't ask again for python3 commands", "   3. No, and tell Claude what to do differently (esc)"]
                   + Array(repeating: "                    ", count: 40)
        precondition(OrcaParse.showsPermissionDialog(tall, needsAlways: true), "dialog above empty rows, with colour codes")
        precondition(OrcaParse.clean(tall).count == 6, "empty rows dropped")
        print("Extras parse tests passed")
    }
}
