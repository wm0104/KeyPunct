// Developer-only: the setter the candidate bar takes its result set through.
function dump(name, re) {
  var cls = ObjC.classes[name];
  if (!cls) { console.log("== " + name + ": MISSING"); return; }
  var out;
  try { out = cls["_methodDescription"](); } catch (e) { console.log("== " + name + ": err " + e); return; }
  var lines = String(out).split("\n").filter(function (l) { return re.test(l); });
  console.log("== " + name + " (" + lines.length + ")");
  console.log(lines.slice(0, 25).join("\n"));
}
dump("UIKeyboardCandidateController", /setCandidateResultSet|candidateResultSet|setCandidates|updateCandidate|reload|showCandidate/);
dump("UIKeyboardImpl", /candidateList|updateCandidateDisplay|setCandidates/);
dump("TUICandidateView", /setCandidates|candidateResultSet|update/);
