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
        print("Extras parse tests passed")
    }
}
