/* Statik denetim: her SB.rpc(...) çağrısı yetki taşıyor mu?

   Denetim bulgusu N-2'nin nöbetçisi. Bir RPC'ye token koymayı unutmak ya da
   "geçici olarak" kimliksiz bir yola düşmek, gözden kaçması en kolay ve en
   pahalı hata. Bu test yeni eklenen her çağrıyı otomatik yakalar.

   Yetki gerektirmeyen tek istisna: giriş kapıları (şifre/PIN alırlar).       */

const fs = require("fs");
const path = require("path");
const { KOK, ok } = require("./yardimci");

const DOSYALAR = ["ortak.js", "bar.html", "depo.html", "admin.html", "index.html"];

// Bir çağrının yetki taşıdığını gösteren izler.
const YETKI = /yetkiArg\(\)|kaptanArg\(\)|p_token/;

// Token TAŞIMAYAN meşru çağrılar: kimliğin kendisini kuran kapılar.
// girisRpc = sifreIleGiris içindeki değişken adı (depo_giris | admin_giris).
const MUAF = new Set(["kaptan_giris", "depo_giris", "admin_giris", "girisRpc"]);

// SB.rpc( ile başlayan çağrının tamamını (dengeli parantez) döndürür.
function cagriMetni(s, bas) {
  let derinlik = 0, tirnak = null;
  for (let i = bas; i < s.length; i++) {
    const c = s[i], onceki = s[i - 1];
    if (tirnak) { if (c === tirnak && onceki !== "\\") tirnak = null; continue; }
    if (c === '"' || c === "'" || c === "`") { tirnak = c; continue; }
    if (c === "(") derinlik++;
    else if (c === ")") { derinlik--; if (derinlik === 0) return s.slice(bas, i + 1); }
  }
  return null;
}

module.exports = async function () {

console.log("\n########## yetki (statik) ##########");

let toplam = 0;
const eksik = [];

for (const f of DOSYALAR) {
  const p = path.join(KOK, f);
  if (!fs.existsSync(p)) continue;
  const s = fs.readFileSync(p, "utf8");
  const re = /SB\.rpc\(/g;
  let m;
  while ((m = re.exec(s)) !== null) {
    const metin = cagriMetni(s, m.index + "SB.rpc".length);
    if (!metin) continue;
    const adEsl = /^\(\s*["']([a-z_]+)["']/.exec(metin);
    const ad = adEsl ? adEsl[1] : (/^\(\s*(\w+)/.exec(metin) || [])[1] || "?";
    toplam++;
    if (MUAF.has(ad)) continue;
    // Argüman nesnesi bir değişkende olabilir: SB.rpc(fn, args).
    // O durumda değişkenin hemen yukarıdaki tanımına bakılır.
    let yetkili = YETKI.test(metin);
    if (!yetkili) {
      const dgs = /,\s*([A-Za-z_$][\w$]*)\s*\)\s*$/.exec(metin);
      if (dgs) {
        const onceki = s.slice(Math.max(0, m.index - 800), m.index);
        const tanim = new RegExp("(?:const|let|var)\\s+" + dgs[1] + "\\s*=[\\s\\S]*$").exec(onceki);
        if (tanim && YETKI.test(tanim[0])) yetkili = true;
      }
    }
    if (!yetkili) {
      const satir = s.slice(0, m.index).split("\n").length;
      eksik.push(f + ":" + satir + "  " + ad);
    }
  }
}

ok("taranan RPC çağrısı var", toplam > 20, "toplam=" + toplam);
ok("yetkisiz RPC çağrısı yok (" + toplam + " çağrı tarandı)", eksik.length === 0, eksik.join(" | "));

// Eski kimlik parametreleri hiçbir yerde geçmemeli (giriş RPC'lerinin p_sifre'si hariç).
for (const f of DOSYALAR) {
  const p = path.join(KOK, f);
  if (!fs.existsSync(p)) continue;
  const s = fs.readFileSync(p, "utf8");
  const kotu = [];
  if (/p_kaptan_pin|p_kaptan_kod/.test(s)) kotu.push("p_kaptan_pin/p_kaptan_kod");
  if (/TOKEN_MODU/.test(s)) kotu.push("TOKEN_MODU");
  // p_sifre yalnızca sifreIleGiris içindeki giriş çağrısında olabilir.
  const sifreSayisi = (s.match(/p_sifre/g) || []).length;
  const izinli = f === "ortak.js" ? 1 : 0;
  if (sifreSayisi > izinli) kotu.push("p_sifre x" + sifreSayisi);
  ok(f + ": eski kimlik parametresi yok", kotu.length === 0, kotu.join(", "));
}

};

if (require.main === module) {
  const { sonuc } = require("./yardimci");
  module.exports().then(() => process.exit(sonuc() ? 0 : 1));
}
