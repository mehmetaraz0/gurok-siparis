/* Her .js dosyası ve her inline <script> bloğu ayrıştırılabiliyor mu?
   Tarayıcı açmadan yakalanabilecek en ucuz hata sınıfı budur. */

const fs = require("fs");
const vm = require("vm");
const cp = require("child_process");
const os = require("os");
const path = require("path");
const { KOK, ok } = require("./yardimci");

const JS = ["ortak.js", "veri.js", "mutfak.js", "tuketim.js", "mutabakat.js", "depo_sablon.js", "config.js"];
const HTML = ["index.html", "bar.html", "depo.html", "admin.html"];

module.exports = async function () {

console.log("\n########## sözdizimi ##########");

for (const f of JS) {
  const p = path.join(KOK, f);
  if (!fs.existsSync(p)) continue;
  let h = null;
  try { new vm.Script(fs.readFileSync(p, "utf8"), { filename: f }); }
  catch (e) { h = e.message; }
  ok(f, h === null, h);
}

for (const f of HTML) {
  const p = path.join(KOK, f);
  if (!fs.existsSync(p)) continue;
  const s = fs.readFileSync(p, "utf8");
  const re = /<script([^>]*)>([\s\S]*?)<\/script>/gi;
  let m, sira = 0, hatalar = [];
  while ((m = re.exec(s)) !== null) {
    if (/\bsrc\s*=/.test(m[1]) || !m[2].trim()) continue;
    sira++;
    const satir = s.slice(0, m.index).split("\n").length;
    if (/type\s*=\s*["']module["']/.test(m[1])) {
      // ESM: vm.Script ayrıştıramaz (import/export), ayrı süreçte --check.
      const gecici = path.join(os.tmpdir(), "gurok_mod_" + process.pid + "_" + sira + ".mjs");
      fs.writeFileSync(gecici, m[2], "utf8");
      const r = cp.spawnSync(process.execPath, ["--check", gecici], { encoding: "utf8" });
      if (r.status !== 0) hatalar.push("blok#" + sira + " (satır ~" + satir + "): " + String(r.stderr || "").split("\n")[3]);
      fs.unlinkSync(gecici);
    } else {
      try { new vm.Script(m[2], { filename: f + "#" + sira }); }
      catch (e) { hatalar.push("blok#" + sira + " (satır ~" + satir + "): " + e.message); }
    }
  }
  ok(f + " (" + sira + " inline blok)", hatalar.length === 0, hatalar.join(" | "));
}

};

if (require.main === module) {
  const { sonuc } = require("./yardimci");
  module.exports().then(() => process.exit(sonuc() ? 0 : 1));
}
