import Foundation

@main
enum WorktreeParseTests {
    static func main() {
        // describe
        let d = WorktreeParse.describe(Data(#"""
        {"version":1,"actions":[{"id":"create","label":"New","scope":"repo","fields":[
          {"id":"name","type":"text","label":"Name","required":true,"pattern":"^[a-z-]+$"},
          {"id":"parts","type":"multi","label":"Parts","options":[{"value":"a","label":"A"}]},
          {"id":"open","type":"bool","label":"Open","default":true}]},
          {"id":"rm","label":"Remove","scope":"worktree","danger":true}]}
        """#.utf8))
        precondition(d?.actions.count == 2 && d?.actions[1].danger == true, "describe")
        let name = d!.actions[0].fields![0]
        precondition(name.problem(with: nil) != nil, "required text missing")
        precondition(name.problem(with: .text("Fix Login")) != nil, "pattern rejects")
        precondition(name.problem(with: .text("fix-login")) == nil, "pattern accepts")
        precondition(d!.actions[0].fields![2].defaultValue == .flag(true), "bool default")

        // run events
        precondition(WorktreeParse.event(#"{"type":"progress","text":"hi"}"#) == .progress("hi"), "progress")
        precondition(WorktreeParse.event("plain output") == .progress("plain output"), "plain line")
        precondition(WorktreeParse.event("   ") == nil, "blank line")
        precondition(WorktreeParse.event(#"{"type":"terminal","command":"claude","cwd":"/x"}"#)
                     == .terminal(command: "claude", cwd: "/x", title: nil), "terminal")
        precondition(WorktreeParse.event(#"{"type":"done","ok":false,"text":"no","risk":["a"],"canForce":true}"#)
                     == .done(ok: false, text: "no", risk: ["a"], canForce: true), "done")

        // git worktree list --porcelain, without the main checkout
        let porcelain = "worktree /r\nHEAD 1\nbranch refs/heads/main\n\nworktree /r-x\nHEAD 2\nbranch refs/heads/x\n\nworktree /r-y\nHEAD 3\ndetached\n"
        let wts = WorktreeParse.gitWorktrees(porcelain)
        precondition(wts.map(\.slug) == ["r-x", "r-y"] && wts[0].branch == "x" && wts[1].branch == nil, "porcelain")

        // arguments
        let a = WorktreeParse.arguments(values: ["name": .text("x")], worktree: wts[0], force: true, confirm: "r-x")
        let o = try! JSONSerialization.jsonObject(with: Data(a.utf8)) as! [String: Any]
        precondition(o["name"] as? String == "x" && o["force"] as? Bool == true && o["confirm"] as? String == "r-x"
                     && (o["worktree"] as? [String: Any])?["path"] as? String == "/r-x", "arguments")
        print("Worktree parse tests passed")
    }
}
