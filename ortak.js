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

// HTML'e basılacak metni kaçışlar.
function htmlEsc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
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

// Ekranda gösterilen kısa kod: CSM315 → 315 (bar), CMM201 → M201 (mutfak)
function kisaKod(kod) {
  kod = String(kod || "");
  return (kod.startsWith("CMM") ? "M" : "") + kod.slice(3);
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
    .map(([g, list]) => [g, list.slice().sort((x, y) => x.a.localeCompare(y.a, "tr"))]);
}

// Gruplanmış sırayla düz liste (Excel satır sırası da bu olur)
function grupluSirala(kalemler, indexFn) {
  return grupla(kalemler, indexFn).flatMap(([, list]) => list);
}
