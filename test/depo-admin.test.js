/* depo.html ve admin.html: giriş, oturum sürdürme, çıkış.

   depo  -> kullanıcı adı + PIN (kaptan_giris, rol="depo")
   admin -> ortak şifre (admin_giris)

   Depo'nun ortak şifresi 1 Eyl 2026'da kapatıldı: sayaç kapı başına
   tutulduğu için yabancı biri 5 yanlış denemeyle tüm depoyu kilitleyebiliyordu
   (denetim N-1). Kişisel girişte sayaç kişiye bağlı.                          */

const { ok, tarayiciKur, KOK } = require("./yardimci");

const DOSYALAR = ["veri.js", "mutfak.js", "ortak.js", "tuketim.js", "mutabakat.js", "depo_sablon.js"];
const depoKur  = o => tarayiciKur(Object.assign({ sayfa: "depo.html",  dosyalar: DOSYALAR }, o));
const adminKur = o => tarayiciKur(Object.assign({ sayfa: "admin.html", dosyalar: DOSYALAR }, o));

const TAZE = () => String(Date.now());

module.exports = async function () {

/* ================= admin.html — ortak şifre ================= */

console.log("\n########## admin.html ##########");

console.log("=== 1. Doğru şifre ===");
{
  const t = adminKur({ rpc: ad => ad === "admin_giris"
    ? { data: { ok: true, token: "TKN_S" }, error: null } : { data: [], error: null } });
  t.getEl("sifre").value = "cokGizliSifre";
  await t.ev("giris()");
  ok("giriş bayrağı açıldı", t.ev("GIRISLI") === true);
  ok("TOKEN alındı", t.ev("TOKEN") === "TKN_S");
  ok("token saklandı", t.ss.getItem("gurok_admin_token") === "TKN_S");
  ok("şifre hiçbir yere yazılmadı",
      !Array.from(t.ss._map.values()).some(v => String(v).indexOf("cokGizliSifre") >= 0),
      JSON.stringify(Array.from(t.ss._map.entries())));
  const gecen = t.cagrilar.filter(c => JSON.stringify(c.arg || {}).indexOf("cokGizliSifre") >= 0);
  ok("şifre yalnızca admin_giris'e gitti",
      gecen.length === 1 && gecen[0].ad === "admin_giris", JSON.stringify(gecen.map(c => c.ad)));
}

console.log("=== 2. Yanlış şifre ===");
{
  const t = adminKur({ rpc: () => ({ data: { ok: false, hata: "Sifre hatali" }, error: null }) });
  t.getEl("sifre").value = "yanlis";
  await t.ev("giris()");
  ok("giriş yapılmadı", t.ev("GIRISLI") === false);
  ok("TOKEN yok", t.ev("TOKEN") === null);
  ok("hata gösterildi", /Şifre hatalı/.test(t.getEl("hata").textContent), t.getEl("hata").textContent);
  // N-2: eski p_sifre yolu silindi; ikinci bir deneme OLMAMALI.
  ok("eski şifre yoluna düşmedi (tek RPC)", t.cagrilar.length === 1,
      JSON.stringify(t.cagrilar.map(c => c.ad)));
  ok("şifre kutusu temizlendi", t.getEl("sifre").value === "");
}

console.log("=== 3. Kilitli hesap ===");
{
  const t = adminKur({ rpc: () => ({ data: { ok: false,
    hata: "Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin." }, error: null }) });
  t.getEl("sifre").value = "x";
  await t.ev("giris()");
  ok("kilit mesajı ekranda", /Çok fazla hatalı deneme/.test(t.getEl("hata").textContent),
      t.getEl("hata").textContent);
}

console.log("=== 4. Yenileme / süre / eski kayıt ===");
{
  const t = adminKur({ oturum: [["gurok_admin_token", "TKN_Y"], ["gurok_admin_zaman", TAZE()]],
                       rpc: () => ({ data: [], error: null }) });
  ok("token'la oturum sürüyor", t.ev("GIRISLI") === true && t.ev("TOKEN") === "TKN_Y");
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

console.log("=== 5. Çıkış ===");
{
  const t = adminKur({ oturum: [["gurok_admin_token", "TKN_C"], ["gurok_admin_zaman", TAZE()]],
                       rpc: () => ({ data: { ok: true }, error: null }) });
  ok("önce giriş yapılmış", t.ev("GIRISLI") === true);
  await t.ev("cikisYap()");
  ok("sunucuya oturum_iptal gitti",
      t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_C"),
      JSON.stringify(t.cagrilar.map(c => c.ad)));
  ok("TOKEN temizlendi", t.ev("TOKEN") === null);
  ok("giriş bayrağı kapandı", t.ev("GIRISLI") === false);
  ok("kilit ekranı geri geldi", t.getEl("kilit").style.display === "");
  ok("şifre kutusu boş", t.getEl("sifre").value === "");
}

/* ================= depo.html — kullanıcı adı + PIN ================= */

console.log("\n########## depo.html ##########");

console.log("=== 6. Ortak şifre yolu KODDAN KALDIRILDI ===");
{
  // Sunucudaki satır silindi; istemcide de ölü kod kalmasın.
  const html = require("fs").readFileSync(require("path").join(KOK, "depo.html"), "utf8");
  ok("ortak şifre kutusu yok", !/id="sifre"/.test(html));
  ok("ortakSifreGiris() yok", html.indexOf("ortakSifreGiris") < 0);
  ok("depo_giris RPC'si artık çağrılmıyor", html.indexOf("depo_giris") < 0);
  ok("kullanıcı adı ve PIN kutuları var", /id="depoKod"/.test(html) && /id="depoPin"/.test(html));
}

console.log("=== 7. Doğru kullanıcı adı + PIN ===");
{
  const t = depoKur({ rpc: ad => ad === "kaptan_giris"
    ? { data: { ok: true, kod: "depocu1", ad: "Depo Personeli", departman: "hepsi",
                rol: "depo", token: "TKN_D" }, error: null }
    : { data: [], error: null } });
  t.getEl("depoKod").value = "DEPOCU1";        // büyük harf de olmalı
  t.getEl("depoPin").value = "111111";
  await t.ev("giris()");
  ok("giriş yapıldı", t.ev("GIRISLI") === true);
  ok("TOKEN alındı", t.ev("TOKEN") === "TKN_D");
  ok("kim girdiği biliniyor", (t.ev("DEPOCU") || {}).ad === "Depo Personeli",
      JSON.stringify(t.ev("DEPOCU")));
  ok("ad başlıkta gösteriliyor", /Depo Personeli/.test(t.getEl("depoKim").textContent),
      t.getEl("depoKim").textContent);
  ok("PIN hiçbir yere yazılmadı",
      !Array.from(t.ss._map.values()).some(v => String(v) === "111111"),
      JSON.stringify(Array.from(t.ss._map.entries())));
  const pinGecen = t.cagrilar.filter(c => JSON.stringify(c.arg || {}).indexOf("111111") >= 0);
  ok("PIN yalnızca kaptan_giris'e gitti",
      pinGecen.length === 1 && pinGecen[0].ad === "kaptan_giris",
      JSON.stringify(pinGecen.map(c => c.ad)));
  ok("PIN kutusu temizlendi", t.getEl("depoPin").value === "");
}

console.log("=== 8. Yanlış PIN ===");
{
  const t = depoKur({ rpc: () => ({ data: { ok: false, hata: "Kaptan kodu veya PIN hatali" }, error: null }) });
  t.getEl("depoKod").value = "depocu1";
  t.getEl("depoPin").value = "000000";
  await t.ev("giris()");
  ok("giriş yapılmadı", t.ev("GIRISLI") === false);
  ok("hata gösterildi", /PIN hatalı/.test(t.getEl("hata").textContent), t.getEl("hata").textContent);
  ok("tek RPC çağrısı", t.cagrilar.length === 1, JSON.stringify(t.cagrilar.map(c => c.ad)));
}

console.log("=== 9. Boş alanlar sunucuya gitmiyor ===");
{
  const t = depoKur({});
  t.getEl("depoPin").value = "111111";
  await t.ev("giris()");
  ok("kullanıcı adı boşken RPC atılmadı", t.cagrilar.length === 0);
  ok("uyarı verildi", /Kullanıcı adı girin/.test(t.getEl("hata").textContent));
}

console.log("=== 10. Kilitli kullanıcı ===");
{
  const t = depoKur({ rpc: () => ({ data: { ok: false,
    hata: "Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin." }, error: null }) });
  t.getEl("depoKod").value = "depocu1";
  t.getEl("depoPin").value = "000000";
  await t.ev("giris()");
  ok("kilit mesajı ekranda", /Çok fazla hatalı deneme/.test(t.getEl("hata").textContent),
      t.getEl("hata").textContent);
}

console.log("=== 11. Kaptan hesabıyla DEPO ekranına girilemez ===");
{
  const t = depoKur({ rpc: ad => ad === "kaptan_giris"
    ? { data: { ok: true, kod: "maraz", ad: "Bir Kaptan", departman: "bar",
                rol: "kaptan", token: "TKN_K" }, error: null }
    : { data: { ok: true }, error: null } });
  t.getEl("depoKod").value = "maraz";
  t.getEl("depoPin").value = "123456";
  await t.ev("giris()");
  ok("giriş REDDEDİLDİ", t.ev("GIRISLI") === false);
  ok("açık mesaj verildi", /depo personeline ait değil/i.test(t.getEl("hata").textContent),
      t.getEl("hata").textContent);
  // Sunucuda oturum açıldı; sahipsiz bırakmadan kapatılmalı.
  ok("açılan oturum sunucuda kapatıldı",
      t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_K"),
      JSON.stringify(t.cagrilar.map(c => c.ad)));
  ok("TOKEN bırakılmadı", t.ev("TOKEN") === null);
}

console.log("=== 12. Yenileme: oturum ve kimlik sürüyor ===");
{
  const t = depoKur({ oturum: [["gurok_depo_token", "TKN_R"], ["gurok_depo_zaman", TAZE()],
                               ["gurok_depo_ad", "Depo Personeli"]],
                      rpc: () => ({ data: [], error: null }) });
  ok("oturum sürdü", t.ev("GIRISLI") === true && t.ev("TOKEN") === "TKN_R");
  ok("ad geri geldi", (t.ev("DEPOCU") || {}).ad === "Depo Personeli", JSON.stringify(t.ev("DEPOCU")));
  ok("başlıkta görünüyor", /Depo Personeli/.test(t.getEl("depoKim").textContent));
}

console.log("=== 13. Süresi dolmuş oturum ===");
{
  const t = depoKur({ oturum: [["gurok_depo_token", "ESKI"],
                               ["gurok_depo_zaman", String(Date.now() - 13 * 3600 * 1000)]],
                      rpc: () => ({ data: [], error: null }) });
  ok("giriş yapılmadı", t.ev("GIRISLI") === false);
  ok("TOKEN yüklenmedi", t.ev("TOKEN") === null);
}

console.log("=== 14. Çıkış ===");
{
  const t = depoKur({ oturum: [["gurok_depo_token", "TKN_C"], ["gurok_depo_zaman", TAZE()],
                               ["gurok_depo_ad", "Depo Personeli"]],
                      rpc: () => ({ data: { ok: true }, error: null }) });
  ok("önce giriş yapılmış", t.ev("GIRISLI") === true);
  await t.ev("cikisYap()");
  ok("sunucuya oturum_iptal gitti",
      t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_C"),
      JSON.stringify(t.cagrilar.map(c => c.ad)));
  ok("TOKEN temizlendi", t.ev("TOKEN") === null);
  ok("giriş bayrağı kapandı", t.ev("GIRISLI") === false);
  ok("kimlik temizlendi", t.ev("DEPOCU") === null);
  ok("ad kaydı silindi", t.ss.getItem("gurok_depo_ad") === null);
  ok("kilit ekranı geri geldi", t.getEl("kilit").style.display === "");
  // Otomatik tazeleme 15 saniyede bir sorgu atıyor; durdurulmazsa çıkıştan
  // sonra ölü token ile sorgulamaya devam ederdi.
  ok("otomatik tazeleme durduruldu",
      t.zamanlayicilar.acilan.length > 0 &&
      t.zamanlayicilar.kapanan.length >= t.zamanlayicilar.acilan.length,
      "acilan=" + t.zamanlayicilar.acilan.length + " kapanan=" + t.zamanlayicilar.kapanan.length);
}

};

if (require.main === module) {
  const { sonuc } = require("./yardimci");
  module.exports().then(() => process.exit(sonuc() ? 0 : 1));
}
