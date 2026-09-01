// ortak.js — bar.html ve depo.html'in PAYLAŞTIĞI mantık.
//
// Excel üretimi burada TEK bir yerde durur. Eski tek-dosya sürümde aynı kurgu
// dlExcel() ve dlAllExcel() içinde iki ayrı kopya halindeydi; biri değişince
// çıktılar sessizce ayrışabiliyordu. Artık bar da depo da aynı fonksiyonu
// çağırdığı için üretilen xlsx birebir aynıdır.

/* ---------- Supabase ---------- */

const SB = supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);

/* ---------- Yardımcılar ---------- */

// XML'e yazılacak metni kaçışlar.
// Katalogda & içeren 33 ürün var (ICE TEA MANGO&ANANAS, CHIWAS SMOOTH&SMOKY,
// KOKTEYL MIX PETBUER&ALMON). Kaçışlanmazsa sheet1.xml bozulur ve Excel
// dosyayı "onarılması gerekiyor" diyerek açmaz.
function xmlEsc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// HTML'e basılacak metni kaçışlar. Tek tırnak da kaçışlanır; ama inline
// onclick gibi bir yerde tek başına yeterli DEĞİLDİR (tarayıcı entity'yi JS
// ayrıştırmasından önce çözer), o yüzden dinamik değerler onclick string'ine
// gömülmez — data-* + addEventListener kullanılır.
function htmlEsc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// Tarayıcı saat dilimine bakmaksızın Türkiye tarihi (YYYY-AA-GG).
function bugun() {
  return new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Istanbul" });
}

function saat(ts) {
  return new Date(ts).toLocaleTimeString("tr-TR", {
    timeZone: "Europe/Istanbul", hour: "2-digit", minute: "2-digit"
  });
}

// "14.08 09:15" — envanterde birden çok güne bakıldığı için gün de gerekli
function tarihSaat(ts) {
  if (!ts) return "—";
  const d = new Date(ts);
  return d.toLocaleDateString("tr-TR", { timeZone: "Europe/Istanbul", day: "2-digit", month: "2-digit" })
       + " " + saat(ts);
}

/* ---------- Düzenlenebilir katalog ---------- */

// Liste kimliği: bar için outlet kodu, mutfak için "kod|bölüm"
function listeKimlik(kod, bolum) {
  return bolum ? kod + "|" + bolum : kod;
}

/* Kimlik hatası artık exception DEĞİL, {ok:false, hata} nesnesi olarak döner.
   Sebep: sunucuda başarısız PIN denemesi kaptan_deneme'ye yazılıyor; raise
   exception transaction'ı geri alır ve o kayıt da silinirdi (bkz. kurulum.sql
   kaptan_dogrula notu). Dolayısıyla PIN alan HER RPC çağrısı dönen değeri
   bu süzgeçten geçirmeli — yoksa hata sessizce "veri" sanılır.
   Dizi dönen fonksiyonlarda (katalog_getir, stok_gizli_kodlar,
   bekleyen_siparisler) nesne gelmesi zaten kimlik hatası demektir. */
function rpcKimlikHatasi(data) {
  return (data && !Array.isArray(data) && typeof data === "object" && data.ok === false)
    ? (data.hata || "Yetki gerekli")
    : null;
}

// Bulut katalogu. OTURUM ŞART: açık oturumun token'ı ile çağrılır (kaptan ya da admin).
// Bulut boşsa/ulaşılamazsa null döner.
async function katalogGetir(liste) {
  try {
    const { data, error } = await SB.rpc("katalog_getir", { p_liste: liste, ...yetkiArg() });
    if (error) throw error;
    const kh = rpcKimlikHatasi(data);
    if (kh) throw new Error(kh);
    return (Array.isArray(data) && data.length) ? data : null;
  } catch (e) {
    console.error("katalog_getir:", e.message || e);
    return null;
  }
}

// Statik veri.js/mutfak.js'ten tüm liste kimliklerini ve kalemlerini üretir
// (admin tohumlaması için). Dönen: [{liste, kalemler:[{k,a,b,g,sira}]}]
function statikListeler() {
  const out = [];
  if (typeof D !== "undefined") {
    D.forEach(o => {
      const sirali = grupluSirala(o.i).map((i, n) => ({ k: i.k, a: i.a, b: i.b, g: i.g, sira: n }));
      out.push({ liste: o.c, kalemler: sirali });
    });
  }
  if (typeof M !== "undefined" && typeof MUTFAK_LISTE !== "undefined") {
    M.forEach(m => m.b.forEach(bolum => {
      const liste = MUTFAK_LISTE[bolum] || [];
      const sirali = grupluSirala(liste, mutfakKatIndex).map((i, n) => ({ k: i.k, a: i.a, b: i.b, g: i.g, sira: n }));
      out.push({ liste: m.c + "|" + bolum, kalemler: sirali });
    }));
  }
  return out;
}

/* ---------- Stok ---------- */

// Bar + mutfak katalogundaki tüm ürün kodları. Stok yalnızca bu kalemler için
// tutulur; KUM raporundaki sipariş dışı gruplar (GNL01 aktivite vb.) elenir.
let _katalogSet = null;
function katalogKodlari() {
  if (_katalogSet) return _katalogSet;
  const s = new Set();
  if (typeof D !== "undefined") D.forEach(o => o.i.forEach(i => s.add(i.k)));
  if (typeof MUTFAK_LISTE !== "undefined")
    Object.values(MUTFAK_LISTE).flat().forEach(i => s.add(i.k));
  _katalogSet = s;
  return s;
}

// Türk sayı biçimi: "48.000,00" → 48000 ; "-2,00" → -2 ; düz "48000" → 48000
function trNum(s) {
  s = String(s ?? "").trim();
  if (s === "") return null;
  if (s.includes(",")) return parseFloat(s.replace(/\./g, "").replace(",", "."));
  const n = parseFloat(s);
  return isNaN(n) ? null : n;
}

// KUM raporu metin satırlarından kalem çıkarır (PDF ve satır-birleştirilmiş Excel).
// Satır: KOD  AD...  BİRİM  d0 d1 .. d9   (10 sayı; d1=Giriş Satın Alma, d9=Kalan)
// Dönen: [{k, a, b, kalan, gelen}]

/* ---------- LN stok raporu (whwmd...xlsx) ----------
   KUM raporu sabit sütun düzenli bir METİN çıktısı; kumParse onu satır satır
   okuyor. LN ise gerçek bir Excel TABLOSU ve sütun düzeni değişebiliyor, o
   yüzden sütunlar başlıktan bulunuyor.

   KRİTİK AYRIM -- LN'de iki ayrı stok sütunu var:
     O 'Eldeki Envanter'  = fiziksel eldeki miktar        <- DOĞRU olan
     R 'Ekonomik Stok'    = eldeki + sipariş envanteri (Q)
   Ekonomik stok henüz GELMEMİŞ malı da sayar; onu kullanmak stoğu şişirir.
   Bu yüzden 'Eldeki Envanter' aranıyor ve kullanıcı önizlemede hangi sütunun
   seçildiğini görüyor (yanlışsa elle değiştirebiliyor).                     */

// Başlık metnini karşılaştırma için sadeleştirir (Türkçe karakter, boşluk, kasa).
function lnNorm(x) {
  return String(x == null ? "" : x).toLocaleLowerCase("tr")
    .replace(/[ıİ]/g, "i").replace(/[şŞ]/g, "s").replace(/[ğĞ]/g, "g")
    .replace(/[üÜ]/g, "u").replace(/[öÖ]/g, "o").replace(/[çÇ]/g, "c")
    .replace(/\s+/g, " ").trim();
}

const LN_KOD = /^[A-Z]{3}\d{8}$/;
const LN_SAYI = /^-?\d+(?:[.,]\d+)?$/;

function lnSayi(v) {
  const t = String(v == null ? "" : v).trim();
  if (!LN_SAYI.test(t)) return null;
  return parseFloat(t.replace(",", "."));
}

/* Bir sayfadaki sütunları bulur.
   Döner: { kodSut, adSut, miktarSut, birimSut, baslikSatir, adaylar[] } ya da
          { hata } -- ne bulunamadığını söyler.
   adaylar: miktar için seçilebilecek sayısal sütunlar (kullanıcı değiştirebilsin). */
function lnSutunBul(rows) {
  if (!rows || !rows.length) return { hata: "Sayfa boş." };

  // 1) Kod sütunu: ürün kodu desenini en çok taşıyan sütun.
  const kodSay = {};
  rows.forEach(r => (r || []).forEach((v, j) => {
    if (LN_KOD.test(String(v == null ? "" : v).trim())) kodSay[j] = (kodSay[j] || 0) + 1;
  }));
  const kodlar = Object.keys(kodSay).sort((a, b) => kodSay[b] - kodSay[a]);
  if (!kodlar.length) return { hata: "Ürün kodu sütunu bulunamadı (ABC12345678 deseni)." };
  const kodSut = +kodlar[0];
  const veriSatirlari = rows.filter(r => LN_KOD.test(String((r || [])[kodSut] ?? "").trim()));

  // 2) Başlık satırı: kod satırlarından ÖNCEKİ, en çok dolu hücresi olan satır.
  const ilkVeri = rows.findIndex(r => LN_KOD.test(String((r || [])[kodSut] ?? "").trim()));
  let baslikSatir = -1, enCok = 0;
  for (let i = 0; i < ilkVeri; i++) {
    const n = (rows[i] || []).filter(v => String(v == null ? "" : v).trim() !== "").length;
    if (n > enCok) { enCok = n; baslikSatir = i; }
  }
  const baslik = j => baslikSatir >= 0 ? String((rows[baslikSatir] || [])[j] ?? "").trim() : "";

  // 3) Sayısal sütun adayları (kod satırlarında).
  const enGenis = Math.max.apply(null, rows.map(r => (r || []).length));
  const adaylar = [];
  for (let j = 0; j < enGenis; j++) {
    let dolu = 0, sayisal = 0;
    for (const r of veriSatirlari) {
      const t = String((r || [])[j] ?? "").trim();
      if (t === "") continue;
      dolu++;
      if (LN_SAYI.test(t)) sayisal++;
    }
    // Sayısal sayılması için kod satırlarının çoğunda dolu VE sayısal olmalı.
    if (dolu >= veriSatirlari.length * 0.9 && sayisal === dolu) {
      adaylar.push({ i: j, baslik: baslik(j) });
    }
  }
  if (!adaylar.length) return { hata: "Sayısal miktar sütunu bulunamadı." };

  // 4) Miktar sütunu: başlığı 'eldeki envanter' olan. Bulunamazsa ilk aday
  //    seçilir ama kullanıcı önizlemede görüp değiştirebilir.
  let miktarSut = -1;
  for (const a of adaylar) if (lnNorm(a.baslik).indexOf("eldeki") >= 0) { miktarSut = a.i; break; }
  if (miktarSut < 0) miktarSut = adaylar[0].i;

  // 5) Ad sütunu: kodun hemen sağındaki metin sütunu (LN'de M).
  let adSut = -1;
  for (let j = kodSut + 1; j < enGenis; j++) {
    let doluMetin = 0;
    for (const r of veriSatirlari) {
      const t = String((r || [])[j] ?? "").trim();
      if (t !== "" && !LN_SAYI.test(t)) doluMetin++;
    }
    if (doluMetin >= veriSatirlari.length * 0.9) { adSut = j; break; }
  }

  // 6) Birim sütunu: başlığı 'birim' olan metin sütunu.
  let birimSut = -1;
  for (let j = 0; j < enGenis; j++) if (lnNorm(baslik(j)) === "birim") { birimSut = j; break; }

  return { kodSut, adSut, miktarSut, birimSut, baslikSatir, adaylar,
           satirSayisi: veriSatirlari.length };
}

// Sütun eşlemesi verilmiş bir sayfayı kalemlere çevirir.
// Döner: [{ k, a, b, m }]  (m = LN'in gösterdiği miktar)
function lnParse(rows, sut) {
  const out = [];
  for (const r of rows || []) {
    const kod = String((r || [])[sut.kodSut] ?? "").trim();
    if (!LN_KOD.test(kod)) continue;
    const m = lnSayi((r || [])[sut.miktarSut]);
    if (m === null) continue;
    out.push({
      k: kod,
      a: sut.adSut >= 0 ? String((r || [])[sut.adSut] ?? "").trim().slice(0, 120) : kod,
      b: sut.birimSut >= 0 ? (String((r || [])[sut.birimSut] ?? "").trim().slice(0, 20) || "ad") : "ad",
      m: m,
    });
  }
  return out;
}

// Sütun harfini gösterir (0 -> A, 14 -> O). Kullanıcı Excel'de doğrulayabilsin.
function lnSutunAdi(i) {
  let s = "";
  i = Number(i);
  while (i >= 0) { s = String.fromCharCode(65 + (i % 26)) + s; i = Math.floor(i / 26) - 1; }
  return s;
}
function kumParse(satirlar) {
  const KOD = /^([A-Z]{3}\d{8})\s+(.+)$/;
  const NUM = /^-?[\d.]*\d(?:,\d+)?$|^-?\d+(?:\.\d+)?$/;
  const out = [];
  for (const raw of satirlar) {
    const t = String(raw ?? "").replace(/\s+/g, " ").trim();
    const m = t.match(KOD);
    if (!m) continue;
    const parca = m[2].split(" ");
    if (parca.length < 11) continue;
    const sayilar = parca.slice(-10);
    if (!sayilar.every(x => NUM.test(x))) continue;
    const birim = parca[parca.length - 11];
    const ad = parca.slice(0, parca.length - 11).join(" ");
    const v = sayilar.map(trNum);
    out.push({ k: m[1], a: ad, b: birim, kalan: v[9], gelen: v[1] });
  }
  return out;
}

// Bar/mutfak: stoğu 0/negatif olan kod kümesi. Stok modülü yoksa boş küme
// döner (hiçbir ürün gizlenmez), böylece sistem eskisi gibi çalışmaya devam eder.
async function stokGizliYukle() {
  if (!TOKEN) return new Set();                                  // oturum yoksa sorgulama
  try {
    const { data, error } = await SB.rpc("stok_gizli_kodlar", kaptanArg());
    if (error) throw error;
    const kh = rpcKimlikHatasi(data);
    if (kh) throw new Error(kh);
    return new Set(data || []);
  } catch (e) {
    console.error("stok_gizli_kodlar:", e.message || e);
    return new Set();
  }
}


/* Tarayıcı deposundan (localStorage/sessionStorage) gelen "kod -> miktar" haritasını
   TEMİZLER. Depo kullanıcı tarafından değiştirilebilir; oradan gelen değer doğrudan
   HTML attribute'una yazılırsa (value="...") attribute enjeksiyonuna açık olur.
   Yalnızca geçerli kalem kodu + pozitif tam sayı geçer. */
function miktarHaritasiTemizle(obj) {
  const temiz = {};
  if (!obj || typeof obj !== "object") return temiz;
  for (const k of Object.keys(obj)) {
    if (!/^[A-Z]{3}[0-9]{8}$/.test(k)) continue;          // kod deseni
    const v = Number(obj[k]);
    if (Number.isInteger(v) && v > 0 && v <= 100000) temiz[k] = v;
  }
  return temiz;
}


/* ---------- Oturum token'ı ----------
   Şifre/PIN YALNIZCA giriş çağrısında gider; sonrasındaki her istek kısa ömürlü
   token ile yapılır. Token sunucuda iptal edilebilir ve süresi dolar.
   TARAYICIDA ŞİFRE/PIN HİÇBİR ZAMAN SAKLANMAZ (M-1).
   Not: token öncesi "eski şifre parametresi" geçiş yolu 1 Eyl 2026'da silindi
   (denetim N-2). Veritabanında eski imzalar zaten drop edilmiş durumda. */
let TOKEN = null;

// Depo/admin çağrıları için yetki argümanı
function yetkiArg() {
  return { p_token: TOKEN };
}

// Kaptan çağrıları için yetki argümanı
function kaptanArg() {
  return { p_token: TOKEN };
}

/* Sunucu mesajları ASCII geliyor (kurulum.sql'de Türkçe karakter yok).
   Ekrana düzgün Türkçe yazar.

   TANIMA AÇIK LİSTEDİR: bilinmeyen sunucu metnini olduğu gibi basmıyoruz
   (gereksiz bilgi sızdırabilir), genel mesaja düşüyoruz. Ama kullanıcının
   EYLEM almasını gerektiren kilit mesajı yutulmamalı — eskiden yutuluyordu
   ve kullanıcı neden giremediğini anlamıyordu. */
function girisHatasiTr(h, varsayilan) {
  if (/cok fazla/i.test(String(h || "")))
    return "Çok fazla hatalı deneme. 15 dakika sonra tekrar deneyin.";
  return varsayilan || "Şifre hatalı.";
}

/* Rol -> hangi ekrana ait. Yanlış ekrana giren kişiye nereye gitmesi
   gerektiğini söylemek için. */
const ROL_EKRANI = {
  kaptan: "sipariş",
  depo_personel: "depo", depo_asistan: "depo", depo_yonetici: "depo",
  departman_yonetici: "depo",
  admin: "yönetim",
};

/* Depo ekranındaki izin matrisi. SUNUCUDAKİNİN AYNASI -- burası yalnızca
   arayüzü sadeleştirmek için; yetkinin kendisi sunucuda (depo_yetki).
   Buradaki bir hata veri sızdırmaz, yalnızca kullanıcıya çalışmayan bir
   düğme gösterir. */
const DEPO_IZIN = {
  depo_personel:      ["talep", "stok_gor"],
  depo_asistan:       ["talep", "stok_gor", "envanter", "stok_yukle"],
  depo_yonetici:      ["talep", "stok_gor", "envanter", "stok_yukle", "stok_sil"],
  departman_yonetici: ["stok_gor", "envanter"],
};

function depoIzinVar(rol, izin) {
  const l = DEPO_IZIN[rol];
  return !!l && l.indexOf(izin) >= 0;
}

const ROL_ADI = {
  depo_personel: "Depo personeli", depo_asistan: "Depo asistanı",
  depo_yonetici: "Depo yöneticisi", departman_yonetici: "Departman yöneticisi",
  kaptan: "Kaptan", admin: "Yönetici",
};

/* Kullanıcı adı + PIN/parola ile giriş. ÜÇ ekran da (bar, depo, yönetim)
   AYNI kapıyı kullanır (kaptan_giris): kapı sayısı arttıkça deneme sayacını
   doğru beslemeyi unutma riski artıyor — H-2'nin dersi buydu. Ortak şifreli
   girişler (depo_giris / admin_giris) 1 Eyl 2026'da kapatıldı.

   beklenenRol: bu ekranın kabul ettiği rol(ler). Tek metin ya da dizi olabilir;
   depo ekranı dört rol kabul ediyor (üç kademe + departman yöneticisi). Sunucu
   oturumu role göre açtığı için yanlış ekrana giren kişi zaten hiçbir şey
   yapamaz; ama "giriş oldu" görünüp sonra her işlemin sessizce reddedilmesi
   kötü bir deneyim. Burada açıkça söylüyoruz.

   Dönüş: { ok:true, kod, ad, departman, rol } | { ok:false, hata }        */
async function kisiGirisi(kod, pin, beklenenRol) {
  const kabul = Array.isArray(beklenenRol) ? beklenenRol : [beklenenRol];
  try {
    const { data, error } = await SB.rpc("kaptan_giris", { p_kod: kod, p_pin: pin });
    // Sunucu hatalı girişte exception atmaz, {ok:false, hata} döner (deneme
    // sayacı commit olsun diye). error dolu ise gerçek bir bağlantı sorunu var.
    if (error) return { ok: false, hata: "Bağlantı kurulamadı." };
    if (!data || data.ok === false || !data.ad)
      return { ok: false, hata: girisHatasiTr(data && data.hata, "Kullanıcı adı veya PIN hatalı.") };
    if (!data.token) return { ok: false, hata: "Sunucu oturum açamadı." };

    const rol = data.rol || "kaptan";
    if (kabul.indexOf(rol) < 0) {
      // Oturum sunucuda açıldı ama bu ekrana ait değil: sahipsiz bırakma, kapat.
      TOKEN = data.token;
      await oturumuKapat();
      return { ok: false,
               hata: "Bu hesap " + (ROL_EKRANI[rol] || rol) + " ekranına ait. Oradan girin." };
    }
    TOKEN = data.token;
    return { ok: true, kod: data.kod || kod, ad: data.ad,
             departman: data.departman || "hepsi", rol: rol };
  } catch (e) { return { ok: false, hata: "Bağlantı kurulamadı." }; }
}

// Token'ı sekme oturumunda sakla.
function tokenKaydet(anahtar) {
  try {
    if (TOKEN) sessionStorage.setItem(anahtar + "_token", TOKEN);
    else sessionStorage.removeItem(anahtar + "_token");
  } catch (e) {}
}

// Sekme oturumundan token'ı geri yükle. Döner: token bulundu mu?
function tokenGeriYukle(anahtar) {
  try {
    if (!oturumTaze(anahtar)) return false;
    const t = sessionStorage.getItem(anahtar + "_token");
    if (!t) return false;
    TOKEN = t; return true;
  } catch (e) { return false; }
}

async function oturumuKapat() {
  if (TOKEN) { try { await SB.rpc("oturum_iptal", { p_token: TOKEN }); } catch (e) {} }
  TOKEN = null;
}
/* ---------- Oturum süresi ----------
   Paylaşılan tablette sekme hiç kapanmıyor; damgasız oturum sabah giren kişinin
   adına akşam sipariş gitmesine yol açar. Girişler MUTLAK süreyle sınırlanır. */
const OTURUM_SAAT = 12;

function oturumDamgala(anahtar) {
  try { sessionStorage.setItem(anahtar + "_zaman", String(Date.now())); } catch (e) {}
}

function oturumTaze(anahtar) {
  try {
    const t = Number(sessionStorage.getItem(anahtar + "_zaman") || 0);
    return t > 0 && (Date.now() - t) < OTURUM_SAAT * 3600 * 1000;
  } catch (e) { return false; }
}
/* ---------- Onaylanan miktar ---------- */

// Bir kalemin Excel'e girecek miktarı.
// m = barın talep ettiği, o = deponun onayladığı (yoksa talep geçerli).
function gecerliMiktar(it) {
  return (it.o === undefined || it.o === null) ? it.m : it.o;
}

// Excel'e girecek kalemler: onaylanan miktar 0 olanlar (verilmeyen ürünler) çıkarılır,
// kalanların miktarı onaylanan değere sabitlenir.
function excelKalemleri(kalemler) {
  return kalemler
    .map(it => ({ ...it, m: gecerliMiktar(it) }))
    .filter(it => it.m > 0);
}

/* ---------- Excel üretimi ---------- */

// kalemler: [{k: kod, a: ad, b: birim, m: miktar}, ...]
// Dönen değer: xlsx Blob'u
async function buildExcelBlob(outletKod, outletAd, kalemler) {
  const tplBytes = Uint8Array.from(atob(TPL_B64), c => c.charCodeAt(0));
  const zip = await JSZip.loadAsync(tplBytes);
  let sheet = await zip.file("xl/worksheets/sheet1.xml").async("string");

  // Şablondaki örnek satırı çıkar
  sheet = sheet.replace(/<row r="2">.*?<\/row>/s, "");

  let newRows = "";
  for (let i = 0; i < kalemler.length; i++) {
    const it = kalemler[i];
    const rn = i + 2;

    let row = ROW2.replace(/r="2"/g, 'r="' + rn + '"');
    row = row.replace(/r="([A-Z]{1,2})2"/g, 'r="$1' + rn + '"');

    const hucre = (sut, icerik) => {
      row = row.replace(new RegExp('<c r="' + sut + rn + '"[^>]*>.*?</c>'), icerik);
    };

    hucre("V",  '<c r="V'  + rn + '" t="inlineStr"><is><t>' + xmlEsc(outletKod) + '</t></is></c>');
    hucre("W",  '<c r="W'  + rn + '" t="inlineStr"><is><t>' + xmlEsc(outletAd)  + '</t></is></c>');
    hucre("AQ", '<c r="AQ' + rn + '" t="n" s="15"><v>' + (i + 1) + '</v></c>');
    hucre("AS", '<c r="AS' + rn + '" t="n" s="15"><v>1</v></c>');
    hucre("AU", '<c r="AU' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.k) + '</t></is></c>');
    hucre("AV", '<c r="AV' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.a) + '</t></is></c>');
    hucre("AW", '<c r="AW' + rn + '" t="n"><v>' + it.m + '.0</v></c>');
    hucre("AX", '<c r="AX' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.b) + '</t></is></c>');
    hucre("AY", '<c r="AY' + rn + '" t="n"><v>' + it.m + '.0</v></c>');
    hucre("AZ", '<c r="AZ' + rn + '" t="inlineStr"><is><t>' + xmlEsc(it.b) + '</t></is></c>');

    newRows += row + "\n";
  }

  sheet = sheet.replace("</sheetData>", newRows + "</sheetData>");
  sheet = sheet.replace(/dimension ref="[^"]*"/, 'dimension ref="A1:BI' + (kalemler.length + 1) + '"');
  zip.file("xl/worksheets/sheet1.xml", sheet);

  return await zip.generateAsync({
    type: "blob",
    mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  });
}

// Excel'i üretip indirir. Onaylanan miktarlar uygulanır, verilmeyen kalemler düşer.
// Dosya adı: siparis_SIP-20260814-007_CSM315.xlsx  (sipariş no yoksa tarih kullanılır)
async function indirExcel(outletKod, outletAd, kalemler, etiket) {
  const secilen = excelKalemleri(kalemler);
  if (!secilen.length) throw new Error("Onaylanan kalem yok");

  const blob = await buildExcelBlob(outletKod, outletAd, secilen);
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "siparis_" + (etiket || bugun()) + "_" + outletKod + ".xlsx";
  a.click();
  URL.revokeObjectURL(url);
}

/* ---------- Katalog yardımcıları ---------- */

// Outlet kodundan outlet nesnesi
function outletBul(kod) {
  return D.find(o => o.c === kod) || null;
}

// Ekranda gösterilen kısa kod: CSM315 → B315 (bar), CMM201 → M201 (mutfak)
function kisaKod(kod) {
  kod = String(kod || "");
  if (kod.startsWith("CMM")) return "M" + kod.slice(3);
  if (kod.startsWith("CSM")) return "B" + kod.slice(3);
  return kod.slice(3);
}

// "M201 ANAMUTFAK · KAHVALTI" / "315 PAVILLION BAR"
function birimAdi(kod, ad, bolum) {
  return kisaKod(kod) + " " + (ad || "") + (bolum ? " · " + bolum : "");
}

// Grup rengi sınıfı (g0..g7 / gd)
function grupSinifi(g) {
  return "g" + (GC[g] ?? "d");
}

/* ---------- Grup sırası ----------
   Katalog ürün KODUNA göre sıralı, gruba göre değil. Bu yüzden ham sırayla
   basıldığında aynı grup listede birkaç kez başlık alıyordu: PREMIX SODA
   ICA01 ailesinde, PREMIX KOLA ICA02 ailesinde olduğu için PREMIX üç ayrı
   yerde çıkıyordu; CSM301'de CARTE D'OR dört, ALGIDA beş ayrı yerdeydi.

   Sıra iki kademeli: önce GC'deki renk kümesi (alkolsüz → alkollü → servis →
   yiyecek → temizlik → hijyen → dondurma → atıştırmalık), sonra GC içindeki
   tanım sırası. Böylece dondurma alt grupları da art arda gelir. */

const GRUP_INDEX = (() => {
  const anahtarlar = Object.keys(GC);
  const tanimSirasi = {};
  anahtarlar.forEach((g, n) => { tanimSirasi[g] = n; });

  const sirali = anahtarlar.slice().sort(
    (a, b) => (GC[a] - GC[b]) || (tanimSirasi[a] - tanimSirasi[b])
  );

  const index = {};
  sirali.forEach((g, n) => { index[g] = n; });
  return index;
})();

// GC'de tanımsız bir grup çıkarsa listenin sonuna düşer (kaybolmaz)
function grupIndex(g) {
  return (g in GRUP_INDEX) ? GRUP_INDEX[g] : 9999;
}

// Bir kod stokta izlenebilir mi? Yiyecek/içecek (YIY/ICA/ICB) her zaman izlenir
// (sipariş katalogunda olmasa bile — sadece stok görünür, sipariş edilemez).
// Diğer aileler (GNL genel/malzeme, DIG diğer) yalnızca katalogda ise izlenir.
function stokUygun(kod) {
  return /^(YIY|ICA|ICB)[0-9]/.test(kod) || katalogKodlari().has(kod);
}

/* ---------- Mutfak kategorileri ----------
   Mutfak listelerinin kategorisi ürün kodundan türetilir (bkz. mutfak.js).
   Bar grupları GC'den, mutfak kategorileri MUTFAK_KAT'tan sıralanır. */

function mutfakKatIndex(g) {
  return (typeof MUTFAK_KAT !== "undefined" && MUTFAK_KAT[g]) ? MUTFAK_KAT[g].s : 999;
}

function mutfakKatSinifi(g) {
  const r = (typeof MUTFAK_KAT !== "undefined" && MUTFAK_KAT[g]) ? MUTFAK_KAT[g].r : 9;
  return r === 9 ? "gd" : "g" + r;
}

// Kalemleri gruba göre öbekler. Dönen değer: [[grupAdı, [kalem, ...]], ...]
// Her grup TEK blok; grup içi ürün adına göre. Sıralama ölçütü dışarıdan
// verilebilir: bar listeleri grupIndex, mutfak listeleri mutfakKatIndex kullanır.
function grupla(kalemler, indexFn) {
  const idx = indexFn || grupIndex;
  const gruplar = new Map();
  kalemler.forEach(it => {
    const g = it.g || "DİĞER";
    if (!gruplar.has(g)) gruplar.set(g, []);
    gruplar.get(g).push(it);
  });

  return [...gruplar.entries()]
    .sort((a, b) => (idx(a[0]) - idx(b[0])) || a[0].localeCompare(b[0], "tr"))
    .map(([g, list]) => [g, list.slice().sort(kalemSirala)]);
}

// Grup içi sıra: elle sıra (sira) verilmişse ona göre, yoksa ürün adına göre.
function kalemSirala(x, y) {
  const sx = x.sira, sy = y.sira;
  if (sx != null && sy != null && sx !== sy) return sx - sy;
  return x.a.localeCompare(y.a, "tr");
}

// Gruplanmış sırayla düz liste (Excel satır sırası da bu olur)
function grupluSirala(kalemler, indexFn) {
  return grupla(kalemler, indexFn).flatMap(([, list]) => list);
}
