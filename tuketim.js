// tuketim.js — tüketim raporu kategorilendirmesi
// Kaynak: haftalik-siparis-takip skill (v2.3). KUM raporundaki 18 sekmeli
// kategori + alt grup mantığı JS'e porte edildi. Sistem, onaylanan
// siparişlerden tüketimi hesaplayıp ürünleri bu kategorilere yerleştirir.
//
// Sistem katalogunda "ürün tipi" yok; Süt/Yoğurt ayrımı gibi tip-bazlı
// kurallar ürün ADINA göre yapılır.

// Kategori gösterim sırası
const TUK_KATEGORILER = [
  "Et ve Tavuk", "Balık ve Deniz Ürünleri", "Süt ve Çeşitleri", "Peynirler",
  "Şoklu Sebze ve Meyve", "Şoklu Unlu Mamuller", "Yoğurt ve Çeşitleri",
  "Yumurta", "Çerez", "Turşu ve Zeytinler", "Makarnalar", "Kek Miksi Çeşitleri",
  "Reçel Dökme", "Kuru Gıda", "Genel Malzeme", "Alkolsüz İçecekler", "Alkollü İçecekler"
];

// Alt gruplu kategorilerin alt grup sırası
const TUK_ALT_SIRA = {
  "Kuru Gıda": ["UN VE HAMUR MALZEMELERİ", "BAKLIYAT VE PİRİNÇ", "KONSERVELER VE YAĞLAR",
                "BAHARATLAR", "SOS VE SİRKE", "ÇİKOLATALAR VE DROP", "DOLGU VE KREMALAR",
                "KURUYEMİŞ VE BİSKÜVİ", "ŞEKER VE TATLI MALZEMELERİ"],
  "Genel Malzeme": ["ECZA VE SAĞLIK", "KIRTASİYE", "KİMYASAL VE TEMİZLİK",
                    "PEÇETELER VE KAĞIT", "ÇÖP TORBALARI", "SERVİS ÜRÜNLERİ"],
  "Alkollü İçecekler": ["BİRALAR", "ŞARAPLAR", "RAKILAR", "VİSKİLER", "VOTKALAR",
                        "CİNLER", "TEQUILA VE RUM", "KANYAKLAR", "LİKÖRLER"]
};

// Kek Miksi — sabit liste (skill). Bu kodlar Kuru Gıda'ya değil, Kek Miksi'ye gider.
const KEK_MIKSI_KODLARI = new Set([
  "YIY07000006","YIY07000007","YIY07000008","YIY07000010","YIY07000015","YIY07000017",
  "YIY07000097","YIY07000100","YIY07000143","YIY09000002","YIY09000004","YIY09000006",
  "YIY09000014","YIY09000015","YIY09000091","YIY09000171","YIY09000236","YIY09000237","YIY09000304"
]);

/* ---------- Alt grup sınıflandırıcıları ---------- */

// Kuru Gıda alt grubu — skill 14.1..14.9 ÖNCELİK SIRASI, ilk eşleşen kazanır.
// Hiçbirine uymayan YIY07/08/09/10/11/12 kalemi HARİÇ tutulur → null döner.
// a = ürün adı (BÜYÜK harf).
function _kuruGidaAlt(kod, a) {
  // 14.1 UN VE HAMUR MALZEMELERI
  if (/^UN$|^UN |NISASTA|KABARTMA TOZU|KARBONAT|OVALEKS|VANILIN|YASMAYA|ALACA CORBA|ALACA ÇORBA|TARHANA|SUSAM|^SIMIT/.test(a))
    return "UN VE HAMUR MALZEMELERİ";
  // 14.2 BAKLIYAT VE PIRINC
  if (/FASULYE|NOHUT|MERCIMEK|BULGUR|PIRINC|PİRİNÇ|BUGDAY ASURE|YULAF|BORULCE|BARBUNYA|KARA BUGDAY|KINOA/.test(a))
    return "BAKLIYAT VE PİRİNÇ";
  // 14.3 KONSERVELER VE YAGLAR
  if (/\bYAG\b|\bYAĞ\b|TEREYAG|TEREYAĞ|MARGARIN|KONSERVE|SALCA|SALÇA|MANTAR SALAMURA|KETCAP|KETÇAP|KAPARI|ENGINAR KALBI|SOYA FILIZI|PATLICAN KOZLENMIS|ZEYTIN SIZMA/.test(a))
    return "KONSERVELER VE YAĞLAR";
  // 14.4 BAHARATLAR
  if (/TUZ|BIBER|KIMYON|TARCIN|TARÇIN|KEKIK|KEKİK|BAHARAT|YENI BAHAR|YENIBAHAR|SAFRAN|NANE|PUL BIBER|KARABIBER|KIRMIZI BIBER|ISOT|SUMAK|ZENCEFIL|MUSKAT|KORI|HASHAS|COREK OTU|KISNIS|DEFNE|ZERDECAL|ZERDEÇAL/.test(a))
    return "BAHARATLAR";
  // 14.5 SOS VE SIRKE
  if (/MAYONEZ|HARDAL|\bSOS\b|SIRKE|BULYON|ACISSO|LIMON SUYU|NAR EKSISI|NAR EKŞİSİ|PATATES PURE|CESNI|ÇEŞNI|SOYA SOS|TERIYAKI|SALSA|ARRABIATA/.test(a))
    return "SOS VE SİRKE";
  // 14.6 CIKOLATALAR VE DROP
  if (/DROP|CIKOLATA|ÇIKOLATA|KAKAO|PRALIN|GANAJ|DAMLA SAKIZI|KUVERTUR/.test(a))
    return "ÇİKOLATALAR VE DROP";
  // 14.7 DOLGU VE KREMALAR
  if (/DOLGU|JOLE|JÖLE|FOND|KREMA|KREM KARAMEL|KREM BRULE|GIDA BOYASI|TARTALET|PANKEK|MELLA|SANTI|TIRAMISU|PASTA KURU|PASTA RESIM|ALGIDA KORNET|PANNA COTTA|AGAR|JELATIN|SABLE|KADIFE BOYA|KULAH|KÜLAH/.test(a))
    return "DOLGU VE KREMALAR";
  // 14.8 KURUYEMIS VE BISKUVI
  if (/FINDIK|BADEM|CEVIZ|FISTIK|GEVREK|BISKUVI|BİSKÜVİ|GOFRET|LOTUS|KAYISI KURU|KAYISI GUN|UZUM KURU|HURMA|INCIR KURU|YABAN MERSINI|HINDISTAN CEVIZI|LEBLEBI|AYCEKIRDEK|KUS UZUMU|CEREZ|ÇEREZ|KRAKER|MAMASI HERO|BEBEK MAMASI|ERIK KURU|CIPS|MISIR GEVREGI|ETIMEK|DUT KURUSU|KETEN/.test(a))
    return "KURUYEMİŞ VE BİSKÜVİ";
  // 14.9 SEKER VE TATLI MALZEMELERI
  if (/SEKER|ŞEKER|\bBAL\b|HELVA|TATLI|LOKUM|BAKLAVA|KOMPOSTO|TAHIN|PEKMEZ|KADAYIF|GULLAC|GÜLLAÇ|MARMELAT|IRMIK|GLIKOZ|HARIBO|PEYNIR TATLISI|KIRAZ SEKERI/.test(a))
    return "ŞEKER VE TATLI MALZEMELERİ";
  return null; // hiçbirine uymadı → HARİÇ
}

function _genelAlt(kod, a) {
  const p5 = kod.slice(0, 5);
  if (p5 === "GNL07") return "ECZA VE SAĞLIK";
  if (p5 === "GNL09") return "KIRTASİYE";
  if (p5 === "GNL16" || p5 === "GNL12") return "SERVİS ÜRÜNLERİ";
  if (p5 === "GNL08") return "PEÇETELER VE KAĞIT";
  if (p5 === "GNL18") {
    if (/COP|ÇÖP/.test(a)) return "ÇÖP TORBALARI";
    if (/PECETE|PEÇETE|HAVLU|KARTON BARDAK/.test(a)) return "PEÇETELER VE KAĞIT";
    return "KİMYASAL VE TEMİZLİK"; // TASKI, SUMA, CLAX, deterjan, fırça, sünger
  }
  return "SERVİS ÜRÜNLERİ";
}

function _alkolluAlt(kod, a) {
  const p5 = kod.slice(0, 5);
  if (p5 === "ICB01" || p5 === "ICB04") return "BİRALAR";
  if (p5 === "ICB02" || p5 === "ICB05") return "ŞARAPLAR";
  if (p5 === "ICB03") {
    if (/RAKI/.test(a)) return "RAKILAR";
    if (/KANYAK|KONYAK/.test(a)) return "KANYAKLAR";
    return "LİKÖRLER"; // ICB03 likör/aperatif
  }
  // ICB07 — isimle ayrış
  if (/RAKI/.test(a)) return "RAKILAR";
  if (/BIRA/.test(a)) return "BİRALAR";
  if (/SARAP|ŞARAP|SAMPANYA|ŞAMPANYA|PROSECCO|FRIZZANTE/.test(a)) return "ŞARAPLAR";
  if (/JACK DAN|JAMESON|WALKER|CHIVAS|GLENLIVET|VISKI|VİSKİ|WHISK|JB |JIM BEAM|BALLANTIN/.test(a)) return "VİSKİLER";
  if (/VOTKA|VODKA|ABSOLUT|SMIRNOFF|GILBEYS|STOLICHNAYA/.test(a)) return "VOTKALAR";
  if (/\bCIN\b|\bCİN\b|BOMBAY|GORDON|HENDRICK|BEEFEATER|TANQUERAY|MALFY|GIN/.test(a)) return "CİNLER";
  if (/TEQUILA|TEKILA|BACARDI|HAVANA|CAPTAIN MORGEN|CAPTAIN MORGAN|MALIBU|\bRUM\b|RHUM|CACHACA|BATIDA/.test(a)) return "TEQUILA VE RUM";
  if (/KANYAK|KONYAK|MARTEL|HENNES|ST.?\s?REMY|METAXA/.test(a)) return "KANYAKLAR";
  if (/BAILEYS|APEROL|CAMPARI|AMARETTO|MARTINI|LIKOR|LİKÖR|JAGER|KAHLUA|SAFARI|ARCHERS|SAMBUCA|FERNET|CHAMBORD|TRIPLE SEC|LIKÖR/.test(a)) return "LİKÖRLER";
  return "LİKÖRLER";
}

// Kuru Gıda'ya yönlendir; alt grup yoksa (hiçbir 14.x kuralına uymuyorsa) HARİÇ tut.
function _kuruGida(kod, a) {
  const alt = _kuruGidaAlt(kod, a);
  return alt ? { tab: "Kuru Gıda", alt } : null;
}

/* ---------- Ana kategorilendirme ---------- */
// Dönen: { tab, alt } veya null (rapora girmez)
function tuketimKategori(kod, ad) {
  kod = String(kod || "");
  const a = String(ad || "").toUpperCase();
  const p3 = kod.slice(0, 3);
  const p5 = kod.slice(0, 5);

  // Kek Miksi (PANKEK CARTE DOR hariç → o Kuru Gıda'da)
  if (KEK_MIKSI_KODLARI.has(kod)) return { tab: "Kek Miksi Çeşitleri" };

  // İçecekler
  if (p3 === "ICA") return { tab: "Alkolsüz İçecekler" };
  if (p3 === "ICB") return { tab: "Alkollü İçecekler", alt: _alkolluAlt(kod, a) };

  // Genel Malzeme — yalnızca dahil GNL aileleri
  if (p3 === "GNL") {
    if (["GNL07", "GNL08", "GNL09", "GNL12", "GNL16", "GNL18"].includes(p5))
      return { tab: "Genel Malzeme", alt: _genelAlt(kod, a) };
    return null; // diğer GNL hariç
  }

  if (p3 !== "YIY") return null;

  // YIY aileleri
  if (p5 === "YIY04") return null;                 // dondurma hariç
  if (p5 === "YIY01") return { tab: "Et ve Tavuk" };
  if (p5 === "YIY02") return { tab: "Balık ve Deniz Ürünleri" };
  if (p5 === "YIY03") return { tab: "Peynirler" };

  if (p5 === "YIY05") {
    if (kod === "YIY05000011") return { tab: "Yumurta" };
    if (/YOGURT|YOĞURT|KAYMAK|AYRAN/.test(a)) return { tab: "Yoğurt ve Çeşitleri" };
    return { tab: "Süt ve Çeşitleri" };
  }

  if (p5 === "YIY06") {
    if (a.startsWith("SOKLU")) return { tab: "Şoklu Sebze ve Meyve" };
    return null;                                    // taze sebze/meyve hariç
  }

  if (p5 === "YIY07") {
    // Kural 6: yalnızca unlu mamul anahtar kelimeleri Şoklu Unlu'ya girer.
    if (/SOKLU|ŞOKLU|KRUVASAN|BOREK|BÖREK|POGACA|POĞAÇA|ICLI KOFTE|İÇLİ KÖFTE|DONUT|GUL BOREGI|KALEM BOREGI|CHURROS|KURABIYE|MANTI|MANTİ/.test(a))
      return { tab: "Şoklu Unlu Mamuller" };
    // Bitmiş/pişmiş ekmekler HARİÇ (hamur/un malzemesi değil — "UN EKMEKLIK" hariç kalır, 14.1'e gider)
    if (/^EKMEK\b|TORTILLA EKMEK|TOST EKMEK/.test(a)) return null;
    // Kalanı (UN, NISASTA, TARHANA, ALACA CORBA…) → Kuru Gıda 14.x
    return _kuruGida(kod, a);
  }

  if (p5 === "YIY08") {
    if (kod === "YIY08000137") return { tab: "Çerez" };
    if (/MAKARNA|SEHRIYE|ŞEHRIYE|SPAGET|ERISTE|MANTI|MANTİ/.test(a)) return { tab: "Makarnalar" };
    return _kuruGida(kod, a);
  }

  if (p5 === "YIY10") {
    if (/RECEL|REÇEL/.test(a)) return { tab: "Reçel Dökme" };
    return _kuruGida(kod, a);
  }

  if (p5 === "YIY11") {
    if (/TURSU|TURŞU|SALGAM|ŞALGAM/.test(a)) return { tab: "Turşu ve Zeytinler" };
    if (/ZEYTIN|ZEYTİN/.test(a) && !/^YAG ZEYTIN|^YAĞ ZEYTIN/.test(a))
      return { tab: "Turşu ve Zeytinler" };        // YAG ZEYTIN SIZMA → Kuru Gıda (Konserve/Yağ)
    return _kuruGida(kod, a);
  }

  // YIY09, YIY12 ve kalan YIY → Kuru Gıda (uymayan HARİÇ)
  return _kuruGida(kod, a);
}
