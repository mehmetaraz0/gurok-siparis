/* depo.html ve admin.html: giriş, oturum sürdürme, çıkış.

   Her ikisi de kişisel giriş kullanıyor (kaptan_giris, rol="depo" / "admin").
   Depo'nun ortak şifresi 1 Eyl 2026'da kapatıldı ve koddan silindi.
   Admin'in ortak şifresi GEÇİŞ boyunca duruyor: ilk yönetici hesabını açmak
   için yönetici yetkisi gerekiyor, yani o kapı kendi kendini kapatamaz.

   Parola kuralı role göre: kaptan/depo 6-12 haneli sayısal PIN (tablette hızlı
   girilsin), yönetici en az 10 karakter serbest metin.                        */

const { ok, tarayiciKur, KOK } = require("./yardimci");
const fs = require("fs");
const path = require("path");

const DOSYALAR = ["veri.js", "mutfak.js", "ortak.js", "tuketim.js", "mutabakat.js", "depo_sablon.js"];
const depoKur  = o => tarayiciKur(Object.assign({ sayfa: "depo.html",  dosyalar: DOSYALAR }, o));
const adminKur = o => tarayiciKur(Object.assign({ sayfa: "admin.html", dosyalar: DOSYALAR }, o));

const TAZE = () => String(Date.now());

// Sunucunun kaptan_giris yanıtını taklit eder.
const girisYaniti = (rol, kod, ad, token) => ad2 =>
  ad2 === "kaptan_giris"
    ? { data: { ok: true, kod: kod, ad: ad, departman: "hepsi", rol: rol, token: token }, error: null }
    : { data: { ok: true }, error: null };

module.exports = async function () {

/* ================= depo.html ================= */

console.log("\n########## depo.html ##########");

console.log("=== 1. Ortak şifre yolu KODDAN KALDIRILDI ===");
{
  const html = fs.readFileSync(path.join(KOK, "depo.html"), "utf8");
  ok("ortak şifre kutusu yok", !/id="sifre"/.test(html));
  ok("ortakSifreGiris() yok", html.indexOf("ortakSifreGiris") < 0);
  ok("depo_giris RPC'si çağrılmıyor", html.indexOf("depo_giris") < 0);
  ok("kullanıcı adı ve PIN kutuları var", /id="depoKod"/.test(html) && /id="depoPin"/.test(html));
}

console.log("=== 2. Doğru kullanıcı adı + PIN ===");
{
  const t = depoKur({ rpc: girisYaniti("depo_yonetici", "depocu1", "Depo Personeli", "TKN_D") });
  t.getEl("depoKod").value = "DEPOCU1";        // büyük harf de olmalı
  t.getEl("depoPin").value = "111111";
  await t.ev("giris()");
  ok("giriş yapıldı", t.ev("GIRISLI") === true);
  ok("TOKEN alındı", t.ev("TOKEN") === "TKN_D");
  ok("kim girdiği biliniyor", (t.ev("DEPOCU") || {}).ad === "Depo Personeli");
  ok("ad başlıkta gösteriliyor", /Depo Personeli/.test(t.getEl("depoKim").textContent));
  ok("PIN hiçbir yere yazılmadı",
      !Array.from(t.ss._map.values()).some(v => String(v) === "111111"),
      JSON.stringify(Array.from(t.ss._map.entries())));
  const pinGecen = t.cagrilar.filter(c => JSON.stringify(c.arg || {}).indexOf("111111") >= 0);
  ok("PIN yalnızca kaptan_giris'e gitti",
      pinGecen.length === 1 && pinGecen[0].ad === "kaptan_giris");
  ok("PIN kutusu temizlendi", t.getEl("depoPin").value === "");
}

console.log("=== 3. Yanlış PIN / kilit / boş alan ===");
{
  const t = depoKur({ rpc: () => ({ data: { ok: false, hata: "Kaptan kodu veya PIN hatali" }, error: null }) });
  t.getEl("depoKod").value = "depocu1"; t.getEl("depoPin").value = "000000";
  await t.ev("giris()");
  ok("giriş yapılmadı", t.ev("GIRISLI") === false);
  ok("hata gösterildi", /PIN hatalı/.test(t.getEl("hata").textContent), t.getEl("hata").textContent);
  ok("tek RPC çağrısı", t.cagrilar.length === 1);
}
{
  const t = depoKur({ rpc: () => ({ data: { ok: false,
    hata: "Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin." }, error: null }) });
  t.getEl("depoKod").value = "depocu1"; t.getEl("depoPin").value = "000000";
  await t.ev("giris()");
  ok("kilit mesajı ekranda", /Çok fazla hatalı deneme/.test(t.getEl("hata").textContent));
}
{
  const t = depoKur({});
  t.getEl("depoPin").value = "111111";
  await t.ev("giris()");
  ok("kullanıcı adı boşken RPC atılmadı", t.cagrilar.length === 0);
  ok("uyarı verildi", /Kullanıcı adı girin/.test(t.getEl("hata").textContent));
}

console.log("=== 4. Başka rollerle DEPO ekranına girilemez ===");
for (const [rol, ekran] of [["kaptan", "sipariş"], ["admin", "yönetim"]]) {
  const t = depoKur({ rpc: girisYaniti(rol, "x", "Biri", "TKN_" + rol) });
  t.getEl("depoKod").value = "x"; t.getEl("depoPin").value = "123456";
  await t.ev("giris()");
  ok(rol + " rolü reddedildi", t.ev("GIRISLI") === false);
  ok(rol + ": doğru ekran söylendi",
      t.getEl("hata").textContent.indexOf(ekran) >= 0, t.getEl("hata").textContent);
  // Sunucuda oturum açıldı; sahipsiz bırakmadan kapatılmalı.
  ok(rol + ": açılan oturum sunucuda kapatıldı",
      t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_" + rol));
  ok(rol + ": TOKEN bırakılmadı", t.ev("TOKEN") === null);
}

console.log("=== 4b. Kademeye göre ekran: hangi sekme görünüyor ===");
{
  // Arayüz gizlemesi SUNUCUNUN AYNASI, güvenlik değil: yetkinin kendisi
  // depo_yetki()'de. Buradaki amaç çalışmayacak düğme göstermemek.
  const gorunur = id => t => t.getEl(id).style.display !== "none";
  const senaryolar = [
    ["depo_personel",      { skTalep: true,  skEnv: false, skTuk: false, skStok: true,
                             stokYukleKutu: false, stokSilKutu: false, yuklemeGecmisi: false }],
    ["depo_asistan",       { skTalep: true,  skEnv: true,  skTuk: true,  skStok: true,
                             stokYukleKutu: true,  stokSilKutu: false, yuklemeGecmisi: true }],
    ["depo_yonetici",      { skTalep: true,  skEnv: true,  skTuk: true,  skStok: true,
                             stokYukleKutu: true,  stokSilKutu: true,  yuklemeGecmisi: true }],
    ["departman_yonetici", { skTalep: false, skEnv: true,  skTuk: true,  skStok: true,
                             stokYukleKutu: false, stokSilKutu: false, yuklemeGecmisi: false }],
  ];
  for (const [rol, beklenen] of senaryolar) {
    const t = depoKur({ rpc: girisYaniti(rol, "u", "Kullanici", "TKN_" + rol) });
    t.getEl("depoKod").value = "u";
    t.getEl("depoPin").value = "111111";
    await t.ev("giris()");
    ok(rol + ": giriş yapıldı", t.ev("GIRISLI") === true);
    const yanlis = Object.keys(beklenen).filter(id => gorunur(id)(t) !== beklenen[id]);
    ok(rol + ": ekran doğru", yanlis.length === 0, "yanlış olanlar: " + yanlis.join(", "));
    ok(rol + ": rol başlıkta yazıyor",
        t.getEl("depoKim").textContent.length > "👤 Kullanici".length,
        t.getEl("depoKim").textContent);
  }
}

console.log("=== 4c. Departman yöneticisi TALEP sorgusu ATMAZ ===");
{
  // Otomatik tazeleme 15 saniyede bir yenile() çağırıyor; talep izni yoksa
  // sunucuya boşuna gidip hata almasın.
  const t = depoKur({ rpc: girisYaniti("departman_yonetici", "dym", "Mutfak Sefi", "TKN_DY") });
  t.getEl("depoKod").value = "dym";
  t.getEl("depoPin").value = "444444";
  await t.ev("giris()");
  t.cagrilar.length = 0;              // giriş çağrısını say dışı bırak
  await t.ev("yenile()");
  ok("depo_liste çağrılmadı", !t.cagrilar.some(c => c.ad === "depo_liste"),
      JSON.stringify(t.cagrilar.map(c => c.ad)));
}

console.log("=== 4d. DEPO TALEPLERİ kutusu doğru rollere görünüyor ===");
{
  // YAŞANAN HATA: talep_yaz izni sunucuya eklendi ama istemcideki DEPO_IZIN
  // aynasına eklenmedi. izinli("talep_yaz") herkes için false döndü ve kutu
  // HİÇ KİMSEYE görünmedi -- hata da vermedi, sadece yoktu.
  const senaryolar = [
    ["depo_personel",      false],
    ["depo_asistan",       true],
    ["depo_yonetici",      true],
    ["departman_yonetici", false],
  ];
  for (const [rol, gorunmeli] of senaryolar) {
    const t = depoKur({ rpc: girisYaniti(rol, "u", "Kullanici", "TKN_" + rol) });
    t.getEl("depoKod").value = "u";
    t.getEl("depoPin").value = "111111";
    await t.ev("giris()");
    const gorunur = t.getEl("talepKutu").style.display !== "none";
    ok(rol + ": talep kutusu " + (gorunmeli ? "GÖRÜNÜYOR" : "gizli"),
        gorunur === gorunmeli, "görünür=" + gorunur);
    // Görünüyorsa listeyi de çekmiş olmalı (boş kutu göstermesin).
    if (gorunmeli) {
      t.cagrilar.length = 0;
      await t.ev('sekmeGec("stok")');
      ok(rol + ": talep listesi çekildi",
          t.cagrilar.some(c => c.ad === "depo_talep_liste"),
          JSON.stringify(t.cagrilar.map(c => c.ad)));
    }
  }
}

console.log("=== 4e. Talep KAYDEDİLİR, indirilmez ===");
{
  // Yazan kişi dosyayı LN'e aktarmıyor; indirmesine gerek yok. Dosyayı
  // listeden aktaracak kişi indiriyor.
  const t = depoKur({ rpc: ad => ad === "kaptan_giris"
    ? { data: { ok: true, kod: "dy", ad: "Depo Yoneticisi", departman: "hepsi",
                rol: "depo_yonetici", token: "TKN_Y" }, error: null }
    : { data: { ok: true, adet: 2 }, error: null } });
  t.getEl("depoKod").value = "dy";
  t.getEl("depoPin").value = "111111";
  await t.ev("giris()");
  // Tüketim ekranında sipariş yazılmış gibi davran
  t.ev('TUKETIM = { kategoriler: { "Alkolsüz İçecekler": { _: [' +
      '{ kod: "ICA02000001", ad: "KOLA", birim: "kol" } ] } } }');
  t.ev('TUK_AKTIF = "Alkolsüz İçecekler"');
  t.ev('TUK_SIPARIS = { ICA02000001: 12 }');
  t.cagrilar.length = 0;
  await t.ev("tukDepoSiparisExcel(false)");
  ok("kayıt RPC'si çağrıldı",
      t.cagrilar.some(c => c.ad === "depo_talep_ekle"),
      JSON.stringify(t.cagrilar.map(c => c.ad)));
  const c = t.cagrilar.find(x => x.ad === "depo_talep_ekle");
  ok("miktar doğru gitti", !!c && c.arg.p_kalemler[0].m === 12);
  ok("liste tazelendi", t.cagrilar.some(x => x.ad === "depo_talep_liste"));
  ok("kullanıcıya KAYDEDİLDİ denildi",
      t.uyarilar.some(u => /KAYDED/i.test(u)), JSON.stringify(t.uyarilar));
  ok("indirme yapılmadı (dosya üretilmedi)",
      !t.uyarilar.some(u => /indi/i.test(u)), JSON.stringify(t.uyarilar));
}

console.log("=== 5. Yenileme / süre / çıkış ===");
{
  const t = depoKur({ oturum: [["gurok_depo_token", "TKN_R"], ["gurok_depo_zaman", TAZE()],
                               ["gurok_depo_ad", "Depo Personeli"]],
                      rpc: () => ({ data: [], error: null }) });
  ok("oturum sürdü", t.ev("GIRISLI") === true && t.ev("TOKEN") === "TKN_R");
  ok("ad geri geldi", (t.ev("DEPOCU") || {}).ad === "Depo Personeli");
}
{
  const t = depoKur({ oturum: [["gurok_depo_token", "ESKI"],
                               ["gurok_depo_zaman", String(Date.now() - 13 * 3600 * 1000)]],
                      rpc: () => ({ data: [], error: null }) });
  ok("süresi dolmuş oturum reddedildi", t.ev("GIRISLI") === false && t.ev("TOKEN") === null);
}
{
  const t = depoKur({ oturum: [["gurok_depo_token", "TKN_C"], ["gurok_depo_zaman", TAZE()],
                               ["gurok_depo_ad", "Depo Personeli"]],
                      rpc: () => ({ data: { ok: true }, error: null }) });
  await t.ev("cikisYap()");
  ok("sunucuya oturum_iptal gitti",
      t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_C"));
  ok("TOKEN ve kimlik temizlendi", t.ev("TOKEN") === null && t.ev("DEPOCU") === null);
  ok("ad kaydı silindi", t.ss.getItem("gurok_depo_ad") === null);
  ok("kilit ekranı geri geldi", t.getEl("kilit").style.display === "");
  // Otomatik tazeleme durdurulmazsa ölü token ile sorgulamaya devam ederdi.
  ok("otomatik tazeleme durduruldu",
      t.zamanlayicilar.acilan.length > 0 &&
      t.zamanlayicilar.kapanan.length >= t.zamanlayicilar.acilan.length);
}

/* ================= admin.html ================= */

console.log("\n########## admin.html — kullanıcı adı + parola ##########");

console.log("=== 6. Doğru kullanıcı adı + parola ===");
{
  const t = adminKur({ rpc: girisYaniti("admin", "yonetici1", "Yönetici Bir", "TKN_A") });
  t.getEl("admKod").value = "YONETICI1";
  t.getEl("admParola").value = "UzunParola2026!";
  await t.ev("giris()");
  ok("giriş yapıldı", t.ev("GIRISLI") === true);
  ok("TOKEN alındı", t.ev("TOKEN") === "TKN_A");
  ok("kim girdiği biliniyor", (t.ev("YONETICI") || {}).ad === "Yönetici Bir");
  ok("ad başlıkta gösteriliyor", /Yönetici Bir/.test(t.getEl("admKim").textContent));
  ok("parola değiştir düğmesi göründü", t.getEl("parolaBtn").style.display === "");
  ok("parola hiçbir yere yazılmadı",
      !Array.from(t.ss._map.values()).some(v => String(v).indexOf("UzunParola2026!") >= 0),
      JSON.stringify(Array.from(t.ss._map.entries())));
  const gecen = t.cagrilar.filter(c => JSON.stringify(c.arg || {}).indexOf("UzunParola2026!") >= 0);
  ok("parola yalnızca kaptan_giris'e gitti",
      gecen.length === 1 && gecen[0].ad === "kaptan_giris");
  ok("parola kutusu temizlendi", t.getEl("admParola").value === "");
}

console.log("=== 7. Başka rollerle YÖNETİM ekranına girilemez ===");
for (const [rol, ekran] of [["kaptan", "sipariş"], ["depo_yonetici", "depo"]]) {
  const t = adminKur({ rpc: girisYaniti(rol, "x", "Biri", "TKN_" + rol) });
  t.getEl("admKod").value = "x"; t.getEl("admParola").value = "UzunParola2026!";
  await t.ev("giris()");
  ok(rol + " rolü reddedildi", t.ev("GIRISLI") === false);
  ok(rol + ": doğru ekran söylendi",
      t.getEl("hata").textContent.indexOf(ekran) >= 0, t.getEl("hata").textContent);
  ok(rol + ": açılan oturum sunucuda kapatıldı",
      t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_" + rol));
}

console.log("=== 8. Yönetici kendi parolasını değiştirir ===");
{
  const t = adminKur({ oturum: [["gurok_admin_token", "TKN_P"], ["gurok_admin_zaman", TAZE()],
                                ["gurok_admin_ad", "Yönetici Bir"]],
                       cevaplar: ["EskiParola2026!", "YeniUzunParola!", "YeniUzunParola!"],
                       rpc: () => ({ data: { ok: true }, error: null }) });
  await t.ev("parolaDegistir()");
  const c = t.cagrilar.find(x => x.ad === "kaptan_sifre_degistir");
  ok("RPC çağrıldı", !!c);
  ok("mevcut parola kullanıcıdan alındı", !!c && c.arg.p_eski_pin === "EskiParola2026!");
  ok("yeni parola gitti", !!c && c.arg.p_yeni_pin === "YeniUzunParola!");
  ok("token ile gitti", !!c && c.arg.p_token === "TKN_P");
  // Sunucu parola değişince tüm oturumları kapatıyor → yeniden giriş şart.
  ok("yeniden girişe yönlendirildi", t.uyarilar.some(u => /tekrar giriş/i.test(u)));
  ok("oturum kapatıldı", t.ev("TOKEN") === null && t.ev("YONETICI") === null);
  ok("onay sorulmadan çıkıldı", t.cagrilar.some(x => x.ad === "oturum_iptal"));
}
{
  const t = adminKur({ oturum: [["gurok_admin_token", "TKN_P"], ["gurok_admin_zaman", TAZE()],
                                ["gurok_admin_ad", "Yönetici Bir"]],
                       cevaplar: ["EskiParola2026!", "kisa"] });
  await t.ev("parolaDegistir()");
  ok("10 karakterden kısa parola reddedildi",
      !t.cagrilar.some(x => x.ad === "kaptan_sifre_degistir"));
  ok("uyarı verildi", t.uyarilar.some(u => /en az 10 karakter/.test(u)));
}

console.log("=== 9. Ortak şifre yolu KODDAN KALDIRILDI ===");
{
  // Sunucudaki satır 1 Eyl 2026'da silindi; istemcide de ölü kod kalmasın.
  const html = fs.readFileSync(path.join(KOK, "admin.html"), "utf8");
  ok("ortak şifre kutusu yok", !/id="sifre"/.test(html));
  ok("ortakSifreGiris() yok", html.indexOf("ortakSifreGiris") < 0);
  ok("admin_giris RPC'si çağrılmıyor", html.indexOf("admin_giris") < 0);
  ok("kullanıcı adı ve parola kutuları var",
      /id="admKod"/.test(html) && /id="admParola"/.test(html));

  // Ortak şifreli giriş yardımcısı da artık hiçbir yerde kullanılmıyor:
  // N-2'nin dersi, kullanılmayan kimlik yolunu bırakmamaktı.
  const ortak = fs.readFileSync(path.join(KOK, "ortak.js"), "utf8");
  ok("sifreIleGiris() ortak.js'ten de silindi", ortak.indexOf("async function sifreIleGiris") < 0);
}

console.log("=== 10. Yenileme / süre / çıkış ===");
{
  const t = adminKur({ oturum: [["gurok_admin_token", "TKN_Y"], ["gurok_admin_zaman", TAZE()],
                                ["gurok_admin_ad", "Yönetici Bir"]],
                       rpc: () => ({ data: [], error: null }) });
  ok("oturum sürdü", t.ev("GIRISLI") === true && t.ev("TOKEN") === "TKN_Y");
  ok("ad geri geldi", (t.ev("YONETICI") || {}).ad === "Yönetici Bir");
}
{
  const t = adminKur({ oturum: [["gurok_admin_sifre", "ESKI_DUZ_SIFRE"], ["gurok_admin_zaman", TAZE()]],
                       rpc: () => ({ data: [], error: null }) });
  ok("eski düz şifre kaydı silindi", t.ss.getItem("gurok_admin_sifre") === null);
  ok("şifreyle otomatik giriş yapılmadı", t.ev("GIRISLI") === false);
}
{
  const t = adminKur({ oturum: [["gurok_admin_token", "ESKI"],
                                ["gurok_admin_zaman", String(Date.now() - 13 * 3600 * 1000)]],
                       rpc: () => ({ data: [], error: null }) });
  ok("süresi dolmuş oturum reddedildi", t.ev("GIRISLI") === false && t.ev("TOKEN") === null);
}
{
  const t = adminKur({ oturum: [["gurok_admin_token", "TKN_C"], ["gurok_admin_zaman", TAZE()],
                                ["gurok_admin_ad", "Yönetici Bir"]],
                       rpc: () => ({ data: { ok: true }, error: null }) });
  await t.ev("cikisYap()");
  ok("sunucuya oturum_iptal gitti",
      t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_C"));
  ok("TOKEN ve kimlik temizlendi", t.ev("TOKEN") === null && t.ev("YONETICI") === null);
  ok("ad kaydı silindi", t.ss.getItem("gurok_admin_ad") === null);
  ok("kilit ekranı geri geldi", t.getEl("kilit").style.display === "");
}

};

if (require.main === module) {
  const { sonuc } = require("./yardimci");
  module.exports().then(() => process.exit(sonuc() ? 0 : 1));
}
