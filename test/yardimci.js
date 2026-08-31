/* Sahte tarayıcı: sayfaları (bar/depo/admin) Node içinde, gerçek dosyalardan
   çalıştırır. Amaç kimlik/oturum akışlarını tarayıcı açmadan doğrulamak.

   Neden vm: ortak.js "const SB", "let TOKEN" gibi ÜST DÜZEY let/const kullanıyor;
   bunlar vm bağlamında nesne özelliği OLMAZ, yalnızca ifadeyle okunur.
   Bu yüzden testler ev("TOKEN") gibi ifadelerle bakar.                       */

const fs = require("fs");
const vm = require("vm");
const path = require("path");

const KOK = path.resolve(__dirname, "..");

let gecti = 0, kaldi = 0;

function ok(ad, sart, ek) {
  if (sart) { console.log("  ✓ " + ad); gecti++; }
  else { console.error("  ✗ " + ad + (ek !== undefined ? "  → " + ek : "")); kaldi++; }
}

function sonuc() {
  console.log("\n" + gecti + " geçti, " + kaldi + " kaldı");
  return kaldi === 0;
}

function depoYap() {
  const m = new Map();
  return {
    getItem: k => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: k => m.delete(k),
    _map: m,
  };
}

function elemanYap(id) {
  return {
    id, value: "", textContent: "", innerHTML: "", disabled: false, checked: false,
    style: {}, dataset: {}, children: [], options: [], selectedIndex: 0,
    classList: { add(){}, remove(){}, toggle(){}, contains: () => false },
    addEventListener(){}, removeEventListener(){}, focus(){}, click(){}, scrollIntoView(){},
    querySelector: () => elemanYap("q"), querySelectorAll: () => [],
    appendChild(){}, insertBefore(){}, remove(){}, setAttribute(){}, getAttribute: () => null,
    closest: () => null,
  };
}

/* opt:
     dosyalar : yüklenecek .js listesi (varsayılan: veri, mutfak, ortak)
     sayfa    : ek olarak bu HTML'in ilk inline <script> bloğu çalıştırılır
     rpc      : (ad, arg) => ({data, error})
     oturum   : [[anahtar, deger], ...] sessionStorage başlangıcı
     cevaplar : prompt() sırayla bunları döndürür
   döner: { ev, cagrilar, uyarilar, sorular, ss, getEl }                       */
function tarayiciKur(opt) {
  opt = opt || {};
  const cagrilar = [], uyarilar = [], sorular = [];
  const elemanlar = new Map();
  const getEl = id => {
    if (!elemanlar.has(id)) elemanlar.set(id, elemanYap(id));
    return elemanlar.get(id);
  };
  const istemci = {
    rpc: async (ad, arg) => {
      cagrilar.push({ ad, arg });
      return (opt.rpc || (() => ({ data: null, error: null })))(ad, arg);
    },
  };
  const ss = depoYap();
  (opt.oturum || []).forEach(kv => ss.setItem(kv[0], kv[1]));
  const cevaplar = (opt.cevaplar || []).slice();

  const ctx = {
    console: { log(){}, error(){}, warn(){} },
    Date, Math, JSON, Set, Map, Number, String, Object, Array, Error, RegExp, Promise,
    parseInt, parseFloat, isNaN,
    setTimeout, clearTimeout, setInterval: () => 0, clearInterval: () => {},
    encodeURIComponent, decodeURIComponent,
    Blob: function(){}, URL: { createObjectURL: () => "blob:x", revokeObjectURL(){} },
    sessionStorage: ss, localStorage: depoYap(),
    supabase: { createClient: () => istemci },
    SUPABASE_URL: "https://ornek.supabase.co", SUPABASE_ANON_KEY: "anon",
    alert: m => uyarilar.push(String(m)),
    prompt: m => { sorular.push(String(m)); return cevaplar.length ? cevaplar.shift() : null; },
    confirm: () => true,
    document: {
      getElementById: getEl, addEventListener(){},
      querySelector: () => elemanYap("q"), querySelectorAll: () => [],
      body: elemanYap("body"), createElement: elemanYap,
    },
    location: { href: "https://gurok.dornevi.com/", reload(){}, search: "" },
    navigator: { onLine: true },
    addEventListener(){}, removeEventListener(){}, dispatchEvent(){},
    XLSX: { utils: {}, write: () => "" }, JSZip: function(){},
  };
  ctx.window = ctx;
  ctx.globalThis = ctx;
  vm.createContext(ctx);

  const dosyalar = opt.dosyalar || ["veri.js", "mutfak.js", "ortak.js"];
  dosyalar.forEach(f => {
    const p = path.join(KOK, f);
    if (fs.existsSync(p)) vm.runInContext(fs.readFileSync(p, "utf8"), ctx, { filename: f });
  });

  if (opt.sayfa) {
    const html = fs.readFileSync(path.join(KOK, opt.sayfa), "utf8");
    const re = /<script([^>]*)>([\s\S]*?)<\/script>/gi;
    let m;
    while ((m = re.exec(html)) !== null) {
      if (/\bsrc\s*=/.test(m[1])) continue;                       // harici dosya
      if (/type\s*=\s*["']module["']/.test(m[1])) continue;       // pdf.js köprüsü
      if (!m[2].trim()) continue;
      vm.runInContext(m[2], ctx, { filename: opt.sayfa + "#inline" });
      break;                                                      // ilk blok = sayfa kodu
    }
  }

  return { ctx, ev: kod => vm.runInContext(kod, ctx), cagrilar, uyarilar, sorular, ss, getEl };
}

module.exports = { KOK, ok, sonuc, tarayiciKur, depoYap, elemanYap };
