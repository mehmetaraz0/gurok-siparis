/* İstemcideki DEPO_IZIN tablosu SUNUCUDAKİ depo_yetki()'nin AYNASI.
   Aynalar sessizce ayrışır: sunucuya izin eklenip istemci unutulursa,
   o izne bağlı ekran parçası HİÇ KİMSEYE görünmez ve hata da vermez.

   Bu tam olarak yaşandı: 'talep_yaz' sunucuya eklendi, istemciye eklenmedi;
   DEPO TALEPLERİ listesi kimseye görünmedi ama talepler kaydolmaya devam etti.
   Test kurulum.sql'i okuyup iki tabloyu birebir karşılaştırıyor.            */

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { KOK, ok } = require("./yardimci");

/* kurulum.sql'deki depo_yetki() gövdesinden izin -> roller tablosunu çıkarır.
   Beklenen biçim:
     when 'izin_adi' then p_rol in ('rol1','rol2')                          */
function sunucuTablosu() {
  const sql = fs.readFileSync(path.join(KOK, "kurulum.sql"), "utf8");
  const bas = sql.indexOf("create or replace function public.depo_yetki");
  if (bas < 0) throw new Error("depo_yetki bulunamadı");
  const son = sql.indexOf("$$;", bas);
  const govde = sql.slice(bas, son);

  const tablo = {};
  const re = /when\s+'([a-z_]+)'\s+then\s+p_rol\s+in\s*\(([^)]*)\)/g;
  let m;
  while ((m = re.exec(govde)) !== null) {
    tablo[m[1]] = m[2].split(",").map(x => x.trim().replace(/^'|'$/g, "")).sort();
  }
  return tablo;
}

/* ortak.js'teki DEPO_IZIN'i rol -> izinler biçiminde okur, izin -> roller'e çevirir. */
function istemciTablosu() {
  const ctx = { console };
  ctx.window = ctx; ctx.globalThis = ctx;
  vm.createContext(ctx);
  const js = fs.readFileSync(path.join(KOK, "ortak.js"), "utf8");
  const bas = js.indexOf("const DEPO_IZIN");
  const son = js.indexOf("};", bas) + 2;
  vm.runInContext(js.slice(bas, son), ctx);
  const rolBazli = vm.runInContext("DEPO_IZIN", ctx);

  const tablo = {};
  for (const rol of Object.keys(rolBazli)) {
    for (const izin of rolBazli[rol]) (tablo[izin] = tablo[izin] || []).push(rol);
  }
  for (const izin of Object.keys(tablo)) tablo[izin].sort();
  return tablo;
}

module.exports = async function () {

console.log("\n########## izin aynası (istemci ↔ sunucu) ##########");

const S = sunucuTablosu();
const I = istemciTablosu();

ok("sunucu tablosu okundu", Object.keys(S).length >= 5, JSON.stringify(Object.keys(S)));
ok("istemci tablosu okundu", Object.keys(I).length >= 5, JSON.stringify(Object.keys(I)));

// 1) Sunucuda olup istemcide olmayan izin: o izne bağlı ekran parçası
//    hiç kimseye görünmez. Sessiz kaybolma.
const eksik = Object.keys(S).filter(x => !I[x]);
ok("sunucudaki her izin istemcide de var", eksik.length === 0,
    "istemcide EKSİK: " + eksik.join(", "));

// 2) İstemcide olup sunucuda olmayan izin: kullanıcıya çalışmayan düğme.
const fazla = Object.keys(I).filter(x => !S[x]);
ok("istemcide fazladan izin yok", fazla.length === 0, "sunucuda YOK: " + fazla.join(", "));

// 3) Her iznin rol listesi birebir aynı olmalı.
for (const izin of Object.keys(S)) {
  if (!I[izin]) continue;                       // (1) zaten raporladı
  ok("  " + izin + ": roller aynı",
      S[izin].join(",") === I[izin].join(","),
      "sunucu=[" + S[izin].join(",") + "] istemci=[" + I[izin].join(",") + "]");
}

// 4) depo.html'de izinli("X") diye sorulan her izin tabloda tanımlı olmalı.
{
  const html = fs.readFileSync(path.join(KOK, "depo.html"), "utf8");
  const kullanilan = new Set();
  const re = /izinli\(\s*"([a-z_]+)"\s*\)/g;
  let m;
  while ((m = re.exec(html)) !== null) kullanilan.add(m[1]);
  ok("depo.html izin kullanıyor", kullanilan.size >= 4, JSON.stringify([...kullanilan]));
  const tanimsiz = [...kullanilan].filter(x => !I[x]);
  ok("izinli(...) çağrılarının hepsi tanımlı", tanimsiz.length === 0,
      "TANIMSIZ: " + tanimsiz.join(", "));
}

};

if (require.main === module) {
  const { sonuc } = require("./yardimci");
  module.exports().then(() => process.exit(sonuc() ? 0 : 1));
}
