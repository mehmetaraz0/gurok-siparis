/* bar.html: kaptan girişi, oturum geri yükleme, PIN değiştirme, çıkış. */

const { ok, tarayiciKur } = require("./yardimci");

const TAZE = () => String(Date.now());
const ACIK_OTURUM = () => [
  ["gurok_kaptan_kod", "maraz"], ["gurok_kaptan_ad", "Mehmet Turan Araz"],
  ["gurok_kaptan_dep", "bar"], ["gurok_kaptan_token", "TKN_P"],
  ["gurok_kaptan_zaman", TAZE()],
];
const barKur = o => tarayiciKur(Object.assign({ sayfa: "bar.html" }, o));

module.exports = async function () {

console.log("\n########## bar.html ##########");

console.log("=== 1. Kaptan girişi ===");
{
  const t = barKur({ rpc: ad => ad === "kaptan_giris"
    ? { data: { ok: true, kod: "maraz", ad: "Mehmet Turan Araz", departman: "bar", token: "TKN_BAR" }, error: null }
    : { data: [], error: null } });
  t.getEl("kaptanKod").value = "MARAZ";       // büyük/küçük harf serbest
  t.getEl("kaptanPin").value = "123456";
  await t.ev("kaptanGiris()");
  const K = t.ev("KAPTAN");
  ok("giriş yapıldı", !!K, JSON.stringify(K));
  ok("KAPTAN nesnesinde PIN yok", K && K.pin === undefined, JSON.stringify(K));
  ok("TOKEN alındı", t.ev("TOKEN") === "TKN_BAR");
  ok("sessionStorage'da PIN yok",
      !Array.from(t.ss._map.values()).some(v => String(v) === "123456"),
      JSON.stringify(Array.from(t.ss._map.entries())));
  ok("token saklandı", t.ss.getItem("gurok_kaptan_token") === "TKN_BAR");
  const pinGecen = t.cagrilar.filter(c => JSON.stringify(c.arg || {}).indexOf("123456") >= 0);
  ok("PIN yalnızca kaptan_giris'e gitti",
      pinGecen.length === 1 && pinGecen[0].ad === "kaptan_giris",
      JSON.stringify(pinGecen.map(c => c.ad)));
}

console.log("=== 2. Kaptan girişi: kilitli hesap ===");
{
  const t = barKur({ rpc: () => ({ data: { ok: false,
    hata: "Cok fazla hatali deneme. 15 dakika sonra tekrar deneyin." }, error: null }) });
  t.getEl("kaptanKod").value = "maraz";
  t.getEl("kaptanPin").value = "000000";
  await t.ev("kaptanGiris()");
  ok("kilit mesajı ekranda", /Çok fazla hatalı deneme/.test(t.getEl("kaptanHata").textContent),
      t.getEl("kaptanHata").textContent);
  ok("giriş yapılmadı", t.ev("KAPTAN") === null);
}

console.log("=== 2b. DEPO hesabıyla sipariş ekranına girilemez ===");
{
  // Sunucu oturumu role göre açtığı için depo hesabı buradan zaten hiçbir şey
  // yapamaz; ama "giriş oldu" görünüp sonra her işlemin sessizce reddedilmesi
  // kötü bir deneyim olurdu. Açık mesaj + açılan oturumu sunucuda kapat.
  const t = barKur({ rpc: ad => ad === "kaptan_giris"
    ? { data: { ok: true, kod: "depocu1", ad: "Depo Personeli", departman: "hepsi",
                rol: "depo", token: "TKN_D" }, error: null }
    : { data: { ok: true }, error: null } });
  t.getEl("kaptanKod").value = "depocu1";
  t.getEl("kaptanPin").value = "111111";
  await t.ev("kaptanGiris()");
  ok("giriş reddedildi", t.ev("KAPTAN") === null);
  ok("doğru ekran söylendi", /depo ekranına ait/.test(t.getEl("kaptanHata").textContent),
      t.getEl("kaptanHata").textContent);
  ok("açılan oturum sunucuda kapatıldı",
      t.cagrilar.some(c => c.ad === "oturum_iptal" && c.arg.p_token === "TKN_D"),
      JSON.stringify(t.cagrilar.map(c => c.ad)));
  ok("TOKEN bırakılmadı", t.ev("TOKEN") === null);
}

console.log("=== 3. Sayfa yenileme: oturum token'dan geri geliyor ===");
{
  const t = barKur({ oturum: ACIK_OTURUM() });
  const K = t.ev("KAPTAN");
  ok("oturum geri geldi", !!K && K.kod === "maraz", JSON.stringify(K));
  ok("PIN alanı yok", K && K.pin === undefined);
  ok("TOKEN yüklendi", t.ev("TOKEN") === "TKN_P");
}

console.log("=== 4. Yenileme sonrası PIN değiştirme ===");
{
  // Regresyon: eskiden p_eski_pin olarak KAPTAN.pin gidiyordu; yenilemeden
  // sonra null olduğu için PIN değiştirme hiç çalışmıyordu.
  const t = barKur({ oturum: ACIK_OTURUM(),
                     cevaplar: ["111111", "654321", "654321"],
                     rpc: () => ({ data: { ok: true }, error: null }) });
  await t.ev("kaptanSifreDegistir()");
  const c = t.cagrilar.find(x => x.ad === "kaptan_sifre_degistir");
  ok("RPC çağrıldı", !!c);
  ok("mevcut PIN kullanıcıdan alındı", !!c && c.arg.p_eski_pin === "111111", c && String(c.arg.p_eski_pin));
  ok("yeni PIN gitti", !!c && c.arg.p_yeni_pin === "654321");
  ok("token ile gitti", !!c && c.arg.p_token === "TKN_P");
  ok("3 soru soruldu (mevcut + yeni + tekrar)", t.sorular.length === 3, JSON.stringify(t.sorular));
  // Sunucu PIN değişince tüm oturumları kapatıyor → token ölü, yeniden giriş şart.
  ok("kullanıcı yeniden girişe yönlendirildi", t.uyarilar.some(u => /tekrar giriş/i.test(u)),
      JSON.stringify(t.uyarilar));
  ok("oturum kapatıldı", t.ev("TOKEN") === null && t.ev("KAPTAN") === null);
  ok("sunucuya oturum_iptal gitti", t.cagrilar.some(x => x.ad === "oturum_iptal"));
}

console.log("=== 5. PIN değiştirme: mevcut PIN yanlış ===");
{
  const t = barKur({ oturum: ACIK_OTURUM(),
                     cevaplar: ["999999", "654321", "654321"],
                     rpc: ad => ad === "kaptan_sifre_degistir"
                       ? { data: null, error: { message: "Eski PIN hatali" } }
                       : { data: null, error: null } });
  await t.ev("kaptanSifreDegistir()");
  ok("hata gösterildi", t.uyarilar.some(u => /Değiştirilemedi/.test(u)), JSON.stringify(t.uyarilar));
  ok("oturum kapatılmadı", t.ev("TOKEN") === "TKN_P" && t.ev("KAPTAN") !== null);
}

console.log("=== 6. PIN değiştirme: mevcut PIN boş ===");
{
  const t = barKur({ oturum: ACIK_OTURUM(), cevaplar: ["  "] });
  await t.ev("kaptanSifreDegistir()");
  ok("RPC atılmadı", !t.cagrilar.some(x => x.ad === "kaptan_sifre_degistir"));
  ok("uyarı verildi", t.uyarilar.some(u => /Mevcut PIN gerekli/.test(u)), JSON.stringify(t.uyarilar));
}

console.log("=== 7. PIN değiştirme: yeni PIN 6 haneden kısa ===");
{
  const t = barKur({ oturum: ACIK_OTURUM(), cevaplar: ["111111", "123"] });
  await t.ev("kaptanSifreDegistir()");
  ok("RPC atılmadı", !t.cagrilar.some(x => x.ad === "kaptan_sifre_degistir"));
  ok("uyarı verildi", t.uyarilar.some(u => /en az 6 haneli/.test(u)), JSON.stringify(t.uyarilar));
}

console.log("=== 8. Çıkış: PIN/token izleri siliniyor ===");
{
  const oturum = ACIK_OTURUM();
  oturum.push(["gurok_kaptan_pin", "ESKI_SURUMDEN_KALMA"]);
  const t = barKur({ oturum, rpc: () => ({ data: { ok: true }, error: null }) });
  await t.ev("kaptanaCik()");
  ok("KAPTAN temizlendi", t.ev("KAPTAN") === null);
  ok("TOKEN temizlendi", t.ev("TOKEN") === null);
  ok("eski PIN kaydı da silindi", t.ss.getItem("gurok_kaptan_pin") === null);
  ok("token kaydı silindi", t.ss.getItem("gurok_kaptan_token") === null);
}

};

if (require.main === module) {
  const { sonuc } = require("./yardimci");
  module.exports().then(() => process.exit(sonuc() ? 0 : 1));
}
