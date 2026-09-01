/* ortak.js: oturum token'ı, yetki argümanları, katalog/stok çağrıları. */

const { ok, tarayiciKur } = require("./yardimci");

module.exports = async function () {

console.log("\n########## ortak.js ##########");

console.log("=== 1. Kişisel giriş: doğru kimlik ===");
{
  // Ortak şifreli giriş (sifreIleGiris) 1 Eyl 2026'da kaldırıldı; üç ekran da
  // kaptan_giris'ten geçiyor ve oturum tipi role göre açılıyor.
  const t = tarayiciKur({ rpc: ad => ad === "kaptan_giris"
    ? { data: { ok: true, kod: "depocu1", ad: "Depo Personeli", departman: "hepsi",
                rol: "depo", token: "TKN123" }, error: null }
    : { data: null, error: null } });
  const r = await t.ev('kisiGirisi("depocu1", "gizliPin", "depo")');
  ok("giriş başarılı", r.ok === true, JSON.stringify(r));
  ok("kimlik döndü", r.ad === "Depo Personeli" && r.rol === "depo");
  ok("token belleğe alındı", t.ev("TOKEN") === "TKN123");
  t.ev('tokenKaydet("gurok_depo")');
  ok("sessionStorage'da token var", t.ss.getItem("gurok_depo_token") === "TKN123");
  ok("sessionStorage'da PIN YOK",
      !Array.from(t.ss._map.values()).some(v => String(v).indexOf("gizliPin") >= 0),
      JSON.stringify(Array.from(t.ss._map.entries())));
  ok("yetkiArg token gönderiyor", JSON.stringify(t.ev("yetkiArg()")) === '{"p_token":"TKN123"}');
  ok("kaptanArg token gönderiyor", JSON.stringify(t.ev("kaptanArg()")) === '{"p_token":"TKN123"}');
  ok("PIN yalnızca kaptan_giris'e gitti",
      t.cagrilar.length === 1 && t.cagrilar[0].ad === "kaptan_giris" &&
      t.cagrilar[0].arg.p_pin === "gizliPin");
}

console.log("=== 2. Kişisel giriş: yanlış PIN ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: { ok: false, hata: "Kaptan kodu veya PIN hatali" }, error: null }) });
  const r = await t.ev('kisiGirisi("depocu1", "yanlis", "depo")');
  ok("giriş reddedildi", r.ok === false);
  ok("mesaj Türkçe", /PIN hatalı/.test(r.hata), r.hata);
  ok("token yok", t.ev("TOKEN") === null);
  // N-2: eski p_sifre yolu silindi; ikinci bir RPC denemesi OLMAMALI.
  ok("eski şifre yoluna düşmedi (tek RPC)", t.cagrilar.length === 1,
      JSON.stringify(t.cagrilar.map(c => c.ad)));
}

console.log("=== 3. Kişisel giriş: hesap kilitli ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: { ok: false,
    hata: "Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin." }, error: null }) });
  const r = await t.ev('kisiGirisi("depocu1", "x", "depo")');
  ok("kilit mesajı kullanıcıya ulaşıyor", /Çok fazla hatalı deneme/.test(r.hata), r.hata);
}

console.log("=== 3b. Rol uyuşmazlığında oturum sunucuda kapatılıyor ===");
{
  const t = tarayiciKur({ rpc: ad => ad === "kaptan_giris"
    ? { data: { ok: true, kod: "maraz", ad: "Kaptan", departman: "bar",
                rol: "kaptan", token: "TKN_X" }, error: null }
    : { data: { ok: true }, error: null } });
  const r = await t.ev('kisiGirisi("maraz", "123456", "admin")');
  ok("giriş reddedildi", r.ok === false);
  ok("doğru ekran söylendi", /sipariş ekranına ait/.test(r.hata), r.hata);
  ok("açılan oturum kapatıldı",
      t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_X"));
  ok("TOKEN bırakılmadı", t.ev("TOKEN") === null);
}

console.log("=== 4. Yenileme: token geri yükleniyor ===");
{
  const t = tarayiciKur({});
  t.ss.setItem("gurok_depo_token", "TKN999");
  t.ev('oturumDamgala("gurok_depo")');
  ok("geri yükleme başarılı", t.ev('tokenGeriYukle("gurok_depo")') === true);
  ok("TOKEN doğru", t.ev("TOKEN") === "TKN999");
}

console.log("=== 5. Yenileme: oturum süresi dolmuş ===");
{
  const t = tarayiciKur({});
  t.ss.setItem("gurok_depo_token", "ESKI");
  t.ss.setItem("gurok_depo_zaman", String(Date.now() - 13 * 3600 * 1000));
  ok("süresi dolmuş oturum reddedildi", t.ev('tokenGeriYukle("gurok_depo")') === false);
  ok("TOKEN yüklenmedi", t.ev("TOKEN") === null);
}

console.log("=== 6. stokGizliYukle: yenilemeden SONRA da çalışıyor ===");
{
  // Regresyon: PIN artık saklanmadığı için eski "kaptan.pin yoksa sorgulama"
  // koşulu, sayfa yenilendikten sonra stok gizlemeyi tamamen kapatıyordu.
  const t = tarayiciKur({ rpc: ad => ad === "stok_gizli_kodlar"
    ? { data: ["ABC12345678", "XYZ87654321"], error: null } : { data: null, error: null } });
  t.ss.setItem("gurok_kaptan_token", "TKN_K");
  t.ev('oturumDamgala("gurok_kaptan")');
  t.ev('tokenGeriYukle("gurok_kaptan")');
  const gizli = await t.ev("stokGizliYukle()");
  ok("stok sorgusu yapıldı", t.cagrilar.some(c => c.ad === "stok_gizli_kodlar"));
  ok("gizli kodlar döndü", gizli.size === 2, "size=" + gizli.size);
  ok("sorgu token ile gitti", t.cagrilar[0] && t.cagrilar[0].arg.p_token === "TKN_K");
}

console.log("=== 7. stokGizliYukle: oturum yokken sorgu atmıyor ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: [], error: null }) });
  const gizli = await t.ev("stokGizliYukle()");
  ok("boş küme", gizli.size === 0);
  ok("gereksiz RPC yok", t.cagrilar.length === 0);
}

console.log("=== 8. katalogGetir: token gönderiyor, eski imzaya düşmüyor ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: [{ k: "A" }], error: null }) });
  t.ev('TOKEN = "TKN_A"');
  const d = await t.ev('katalogGetir("CSM101")');
  ok("katalog döndü", Array.isArray(d) && d.length === 1);
  ok("tek çağrı (fallback yok)", t.cagrilar.length === 1);
  ok("p_token gitti", t.cagrilar[0].arg.p_token === "TKN_A");
  ok("p_kaptan_pin gitmedi", t.cagrilar[0].arg.p_kaptan_pin === undefined);
  ok("p_sifre gitmedi", t.cagrilar[0].arg.p_sifre === undefined);
}

console.log("=== 9. katalogGetir: yetki hatası yutulmuyor ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: { ok: false, hata: "Yetki gerekli" }, error: null }) });
  t.ev('TOKEN = "SAHTE"');
  ok("null döndü", (await t.ev('katalogGetir("CSM101")')) === null);
}

console.log("=== 10. Çıkış ===");
{
  const t = tarayiciKur({ rpc: () => ({ data: { ok: true }, error: null }) });
  t.ev('TOKEN = "TKN_C"');
  await t.ev("oturumuKapat()");
  ok("oturum_iptal çağrıldı", t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_C"));
  ok("TOKEN temizlendi", t.ev("TOKEN") === null);
  t.ev('tokenKaydet("gurok_depo")');
  ok("sessionStorage'daki token silindi", t.ss.getItem("gurok_depo_token") === null);
}

console.log("=== 11. miktarHaritasiTemizle (attribute enjeksiyonu koruması) ===");
{
  const t = tarayiciKur({});
  const kirli = { "ABC12345678": 5, '" autofocus onfocus=alert(1) x="': 3,
                  "ABC12345679": -2, "ABC12345670": "9" };
  const temiz = t.ev("miktarHaritasiTemizle(" + JSON.stringify(kirli) + ")");
  ok("geçerli kod geçti", temiz["ABC12345678"] === 5);
  ok("enjeksiyon anahtarı elendi",
      Object.keys(temiz).every(k => /^[A-Z]{3}[0-9]{8}$/.test(k)), JSON.stringify(Object.keys(temiz)));
  ok("negatif elendi", temiz["ABC12345679"] === undefined);
  ok("sayıya çevrilen geçti", temiz["ABC12345670"] === 9);
}

console.log("=== 12. LN stok raporu ayrıştırıcısı ===");
{
  // Gerçek LN çıktısının (whwmd...xlsx) yapısı: başlık 1. satırda, kodlar L
  // sütununda, ad M, RAF N, "Eldeki Envanter" O, "Ekonomik Stok" R, "Birim" S.
  const B = (i, v) => { const r = []; r[i] = v; return r; };
  const satir = (kod, ad, raf, eldeki, ayrilmis, siparis, ekonomik, birim) => {
    const r = [];
    r[3] = "809"; r[4] = "100"; r[5] = "CLUB ISLETME DEPO"; r[7] = "810";
    r[11] = kod; r[12] = ad; r[13] = raf; r[14] = eldeki;
    r[15] = ayrilmis; r[16] = siparis; r[17] = ekonomik; r[18] = birim;
    return r;
  };
  const baslik = [];
  baslik[0] = "Import Status"; baslik[3] = "Company"; baslik[4] = "Depo";
  baslik[10] = "Kalem"; baslik[13] = "RAF"; baslik[14] = "Eldeki Envanter";
  baslik[15] = "Ayrılmış Envanter"; baslik[16] = "Sipariş Envanteri";
  baslik[17] = "Ekonomik Stok"; baslik[18] = "Birim";
  const rows = [baslik,
    satir("ICB01000003", "BIRA SISE 33 CL 30 LU", "BIRA SIS", "0",  "0", "126", "126", "kol"),
    satir("ICB01000005", "BIRA FICI 50 LT",       "",         "23", "0", "0",   "23",  "fic"),
    satir("ICB01000010", "BIRA MALT 25 CL 24 LU", "ALK25",    "8",  "0", "0",   "8",   "kol"),
    satir("ICB01000011", "BIRA SISE 30 CL 24 LU", "BIRA1",    "78", "0", "126", "204", "kol")];

  const t = tarayiciKur({});
  t.ctx.__rows = rows;
  const sut = t.ev("lnSutunBul(__rows)");
  ok("hata yok", !sut.hata, sut.hata);
  ok("kod sütunu L", t.ev("lnSutunAdi(" + sut.kodSut + ")") === "L");
  ok("ad sütunu M", t.ev("lnSutunAdi(" + sut.adSut + ")") === "M");
  ok("birim sütunu S", t.ev("lnSutunAdi(" + sut.birimSut + ")") === "S");
  // EN KRİTİK: "Eldeki Envanter" (fiziksel) seçilmeli, "Ekonomik Stok" DEĞİL.
  // Ekonomik stok henüz gelmemiş sipariş envanterini de içeriyor; onu almak
  // stoğu şişirir (gerçek dosyada 60 üründe 5320 birim fark vardı).
  ok("miktar sütunu O (Eldeki Envanter)",
      t.ev("lnSutunAdi(" + sut.miktarSut + ")") === "O",
      t.ev("lnSutunAdi(" + sut.miktarSut + ")"));
  ok("R (Ekonomik Stok) seçilmedi", t.ev("lnSutunAdi(" + sut.miktarSut + ")") !== "R");

  t.ctx.__sut = sut;
  const kalemler = t.ev("lnParse(__rows, __sut)");
  ok("4 kalem ayrıştırıldı", kalemler.length === 4, String(kalemler.length));
  ok("miktarlar doğru",
      kalemler.map(k => k.m).join(",") === "0,23,8,78",
      kalemler.map(k => k.m).join(","));
  ok("birimler doğru", kalemler.map(k => k.b).join(",") === "kol,fic,kol,kol");
  ok("adlar doğru", kalemler[1].a === "BIRA FICI 50 LT", kalemler[1].a);

  // Kullanıcı sütunu değiştirebilmeli (LN formatı değişirse tek çıkış yolu).
  const R = sut.adaylar.find(a => a.baslik === "Ekonomik Stok");
  ok("Ekonomik Stok aday listesinde var", !!R);
  t.ctx.__sutR = Object.assign({}, sut, { miktarSut: R.i });
  const yanlis = t.ev("lnParse(__rows, __sutR)");
  ok("elle seçilen sütun kullanılıyor",
      yanlis.map(k => k.m).join(",") === "126,23,8,204",
      yanlis.map(k => k.m).join(","));
}

console.log("=== 12b. LN: kod sütunu yoksa açık hata ===");
{
  const t = tarayiciKur({});
  t.ctx.__rows = [["a", "b"], ["1", "2"]];
  const sut = t.ev("lnSutunBul(__rows)");
  ok("hata döndü", !!sut.hata);
  ok("hata anlaşılır", /Ürün kodu/.test(sut.hata), sut.hata);
}
};

if (require.main === module) {
  const { sonuc } = require("./yardimci");
  module.exports().then(() => process.exit(sonuc() ? 0 : 1));
}
