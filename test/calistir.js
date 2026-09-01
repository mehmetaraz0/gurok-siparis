/* Tüm testleri koşar.  Kullanım:  node test/calistir.js
   Tek dosya:  node test/bar.test.js
   Bağımlılık yok; yalnızca Node gerekir.                                     */

const { sonuc } = require("./yardimci");

const TESTLER = [
  "./sozdizimi.test",
  "./yetki.test",
  "./izin-aynasi.test",
  "./ortak.test",
  "./bar.test",
  "./depo-admin.test",
];

(async () => {
  for (const t of TESTLER) await require(t)();
  const temiz = sonuc();
  if (!temiz) console.error("\nBAŞARISIZ — yukarıdaki ✗ satırlarına bakın.");
  process.exit(temiz ? 0 : 1);
})().catch(e => { console.error(e); process.exit(1); });
