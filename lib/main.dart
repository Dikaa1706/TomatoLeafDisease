import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_tflite/flutter_tflite.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const AplikasiTomat());
}

/// Widget akar (root) dari aplikasi Klinik Daun Tomat.
///
/// Mengatur tema global (skema warna, latar belakang) dan menetapkan
/// [BerandaScreen] sebagai halaman pertama yang ditampilkan.
class AplikasiTomat extends StatelessWidget {
  const AplikasiTomat({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Deteksi Penyakit Tomat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1FA45C)),
        scaffoldBackgroundColor: const Color(0xFFF4F7F4),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const BerandaScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// Halaman utama aplikasi.
///
/// Menampilkan area untuk mengambil/memilih foto daun tomat, menjalankan
/// deteksi penyakit dengan model TensorFlow Lite secara lokal, dan (bila
/// penyakit terdeteksi) meminta saran penanganan dari Gemini API.
class BerandaScreen extends StatefulWidget {
  const BerandaScreen({super.key});

  @override
  State<BerandaScreen> createState() => _BerandaScreenState();
}

class _BerandaScreenState extends State<BerandaScreen> {
  File? _image;
  List? _hasilPrediksi;
  bool _sedangMemuat = false;
  bool _sedangMemuatGemini = false;
  bool _modelSiap = false;
  String _rekomendasiGemini = "";
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _sedangMemuat = true;
    _muatModelAI().then((value) {
      setState(() {
        _sedangMemuat = false;
      });
    });
  }

  /// Memuat model TensorFlow Lite (`assets/model_tomat.tflite`) beserta
  /// daftar labelnya (`assets/labels.txt`) ke memori.
  ///
  /// Harus selesai (ditandai [_modelSiap] menjadi `true`) sebelum tombol
  /// kamera/galeri bisa dipakai — lihat [_ambilGambar].
  Future<void> _muatModelAI() async {
    try {
      await Tflite.loadModel(
        model: "assets/model_tomat.tflite",
        labels: "assets/labels.txt",
        numThreads: 1,
        isAsset: true,
        useGpuDelegate: false,
      );
      print("Model AI berhasil dimuat!");
      setState(() {
        _modelSiap = true;
      });
    } catch (e) {
      print("Gagal memuat model: $e");
    }
  }

  /// Mengambil gambar dari [sumber] (kamera atau galeri), lalu langsung
  /// memicu [_deteksiPenyakit] terhadap gambar tersebut.
  ///
  /// Tidak melakukan apa-apa selain menampilkan pesan jika model AI
  /// ([_modelSiap]) belum selesai dimuat.
  Future<void> _ambilGambar(ImageSource sumber) async {
    if (!_modelSiap) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Tunggu sebentar, AI sedang bersiap...")));
      return;
    }

    final XFile? gambarDipilih = await _picker.pickImage(source: sumber);

    if (gambarDipilih != null) {
      setState(() {
        _sedangMemuat = true;
        _image = File(gambarDipilih.path);
        _hasilPrediksi = null;
        _rekomendasiGemini = "";
      });
      // Setelah gambar diperoleh, langsung jalankan AI lokal
      _deteksiPenyakit(_image!.path);
    }
  }

  /// Meminta saran penanganan dari Gemini API untuk [namaPenyakit] yang
  /// terdeteksi, dan mengembalikannya sebagai teks berformat 3 poin bernomor
  /// (penyebab → tindakan segera → pencegahan/pengobatan).
  ///
  /// Jika terjadi error (jaringan, timeout, atau respons API tidak valid),
  /// fungsi ini mengembalikan pesan error yang sudah diformat untuk
  /// ditampilkan langsung ke user — bukan melempar exception.
  ///
  /// Catatan teknis:
  /// - Model `gemini-1.5-flash` (dan semua model Gemini 1.0/1.5) sudah
  ///   dihentikan oleh Google → SELALU 404 apa pun versi endpoint-nya.
  ///   Gunakan model aktif seperti `gemini-2.5-flash` atau `gemini-3.5-flash`.
  /// - Endpoint resmi Gemini API saat ini menggunakan versi `v1beta`.
  Future<String> _ambilSaranGemini(String namaPenyakit) async {
    // 💡 API Key TIDAK di-hardcode di sini — dibaca dari environment variable
    // saat build/run, lewat --dart-define-from-file (lihat file env.json &
    // README bagian "Konfigurasi API Key Gemini"). Ini penting karena repo
    // publik: kalau key ditulis langsung di kode, siapa pun yang buka repo
    // (atau lihat histori commit) bisa lihat dan pakai key kamu.
    const String apiKey = String.fromEnvironment('GEMINI_API_KEY');

    if (apiKey.isEmpty) {
      return "⚠️ API Key Gemini belum diatur!\n\nJalankan aplikasi dengan:\nflutter run --dart-define-from-file=env.json\n\nLihat README bagian 'Konfigurasi API Key Gemini' untuk cara bikin file env.json-nya.";
    }

    // 💡 Nama model yang masih aktif per Juli 2026.
    // Alternatif lain: "gemini-2.5-flash-lite" (lebih murah/cepat) atau
    // "gemini-3.5-flash" (paling baru, kualitas lebih tinggi, lebih mahal).
    const String namaModel = "gemini-2.5-flash";

    // 💡 Endpoint resmi Gemini API saat ini menggunakan versi v1beta.
    final String url =
        "https://generativelanguage.googleapis.com/v1beta/models/$namaModel:generateContent?key=$apiKey";

    final String promptUtama =
        "Kamu adalah asisten tanaman yang santai tapi paham banget soal penyakit tomat, kayak teman yang kebetulan ahli pertanian. "
        "Jawab langsung ke inti masalah, TANPA basa-basi pembuka seperti 'Selamat siang/pagi', 'Halo Bapak/Ibu', atau sapaan formal apa pun — "
        "langsung mulai dengan membahas penyakitnya. Gunakan bahasa Indonesia sehari-hari yang santai dan hangat (boleh pakai 'kamu', "
        "hindari kata-kata kaku seperti 'Bapak/Ibu Tani' atau 'Sistem Instruksi'), tetap jelas, singkat per poin, dan mudah dipraktikkan. "
        "Boleh sesekali pakai emoji secukupnya biar tidak kaku, tapi jangan berlebihan.\n\n"
        "Tanaman tomatnya kena penyakit: $namaPenyakit. Jelaskan dengan format poin-poin singkat:\n"
        "1. Kenapa ini bisa kena (penyebab utama)\n"
        "2. Apa yang harus segera dilakukan sekarang\n"
        "3. Cara mencegah/mengobati yang aman dan gampang didapat bahannya";

    final Map<String, dynamic> payload = {
      "contents": [
        {
          "parts": [
            {"text": promptUtama}
          ]
        }
      ]
    };

    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final String? teksHasil =
            data['candidates']?[0]?['content']?['parts']?[0]?['text'];
        if (teksHasil != null && teksHasil.isNotEmpty) {
          return teksHasil;
        }
        return "⚠️ Respons dari Gemini kosong atau formatnya tidak sesuai dugaan.\n\nRaw response:\n${response.body}";
      }

      // 💡 Tangani body error dengan aman, jangan langsung jsonDecode tanpa try/catch
      // karena body error tidak selalu berupa JSON valid.
      String errMsg = "Ada kendala pada server.";
      try {
        final Map<String, dynamic> errData = jsonDecode(response.body);
        errMsg = errData['error']?['message'] ?? errMsg;
      } catch (_) {
        errMsg = response.body;
      }
      return "❌ Error Server Google Gemini (Status ${response.statusCode}):\n\nPesan: $errMsg";
    } catch (e, stackTrace) {
      // 🔍 DEBUG: cetak exception asli + tipe class-nya ke console `flutter run`
      // supaya kita tahu ini SocketException, TimeoutException, HandshakeException, dll.
      print("=== ERROR GEMINI ===");
      print("Tipe: ${e.runtimeType}");
      print("Pesan: $e");
      print("StackTrace: $stackTrace");
      print("=====================");

      return "⚠️ Gagal Melakukan Koneksi!\n\nTipe Error: ${e.runtimeType}\nDetail Sistem: ${e.toString()}\n\nSolusi Penanganan:\n1. Pastikan Anda sudah menambahkan izin INTERNET di 'AndroidManifest.xml'.\n2. Pastikan HP fisik Anda memiliki koneksi internet aktif.";
    }
  }

  /// Menjalankan model TFLite terhadap gambar di [pathGambar], menyimpan
  /// hasilnya ke [_hasilPrediksi], dan — bila hasilnya bukan "sehat" dengan
  /// keyakinan ≥ 55% — memanggil [_ambilSaranGemini] untuk mendapatkan saran
  /// penanganan.
  Future<void> _deteksiPenyakit(String pathGambar) async {
    try {
      double meanValue = 0.0;
      double stdValue = 1.0;

      var hasil = await Tflite.runModelOnImage(
        path: pathGambar,
        imageMean: meanValue,
        imageStd: stdValue,
        numResults: 1,
        threshold: 0.1,
        asynch: true,
      );

      setState(() {
        _hasilPrediksi = hasil;
        _sedangMemuat = false;
      });

      // Jika terdeteksi sakit dengan akurasi memadai, konsultasikan ke Gemini
      if (hasil != null && hasil.isNotEmpty) {
        double confidence = hasil[0]["confidence"];
        String label = hasil[0]["label"];

        bool isSehat = confidence < 0.55 ||
            label.toLowerCase().contains("healthy") ||
            label.toLowerCase().contains("sehat");

        if (!isSehat) {
          setState(() {
            _sedangMemuatGemini = true;
          });

          String namaPenyakitRapi = label.replaceAll("_", " ");
          String saranDariGemini = await _ambilSaranGemini(namaPenyakitRapi);

          setState(() {
            _rekomendasiGemini = saranDariGemini;
          });
        }
      }
    } catch (e) {
      print("Error saat mendeteksi: $e");
    } finally {
      setState(() {
        _sedangMemuat = false;
        _sedangMemuatGemini = false;
      });
    }
  }

  @override
  void dispose() {
    Tflite.close(); // Tutup memori AI lokal
    super.dispose();
  }

  // Palet warna modern — hijau segar sebagai warna utama, oranye untuk aksen peringatan
  static const Color _primer = Color(0xFF1FA45C); // hijau segar
  static const Color _primerGelap = Color(0xFF0D7A3F);
  static const Color _aksenWarning = Color(0xFFF59E0B); // amber hangat
  static const Color _latarLembut = Color(0xFFF4F7F4);
  static const Color _teksUtama = Color(0xFF1B2420);
  static const Color _teksSamar = Color(0xFF6B7A70);

  @override
  Widget build(BuildContext context) {
    bool isSehat = false;
    String namaTampilan = "";
    double akurasi = 0.0;

    if (_hasilPrediksi != null && _hasilPrediksi!.isNotEmpty) {
      akurasi = _hasilPrediksi![0]["confidence"];
      String labelRaw = _hasilPrediksi![0]["label"].toString().toLowerCase();

      if (akurasi < 0.55) {
        isSehat = true;
        namaTampilan = "Daunnya keliatan sehat kok 😊";
      } else if (labelRaw.contains("healthy") || labelRaw.contains("sehat")) {
        isSehat = true;
        namaTampilan = "Daun Tomat Sehat! 🌿";
      } else {
        isSehat = false;
        namaTampilan =
            _hasilPrediksi![0]["label"].toString().replaceAll("_", " ");
      }
    }

    return Scaffold(
      backgroundColor: _latarLembut,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // --- HEADER MODERN ---
            SliverToBoxAdapter(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_primer, _primerGelap],
                  ),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(36),
                    bottomRight: Radius.circular(36),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Center(
                        child: Text('🍅', style: TextStyle(fontSize: 26)),
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Klinik Daun Tomat',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: 0.2,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Cek kondisi tanamanmu pakai AI',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _ChipStatusModel(siap: _modelSiap),
                  ],
                ),
              ),
            ),

            // --- KONTEN UTAMA (kartu melayang di atas header) ---
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  Transform.translate(
                    offset: const Offset(0, -22),
                    child: Column(
                      children: [
                        // --- PREVIEW GAMBAR ---
                        _KartuFoto(
                          image: _image,
                          onTap: _modelSiap
                              ? () => _tampilkanPilihanSumber(context)
                              : null,
                        ),

                        const SizedBox(height: 18),

                        // --- HASIL DETEKSI (dengan transisi halus) ---
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: _sedangMemuat
                              ? const _KartuMemuat(
                                  key: ValueKey('memuat'),
                                  pesan: 'Lagi menganalisis daunnya...',
                                )
                              : (_hasilPrediksi != null &&
                                      _hasilPrediksi!.isNotEmpty)
                                  ? Column(
                                      key: const ValueKey('hasil'),
                                      children: [
                                        _KartuHasil(
                                          isSehat: isSehat,
                                          namaTampilan: namaTampilan,
                                          akurasi: akurasi,
                                          warnaPrimer: _primer,
                                          warnaWarning: _aksenWarning,
                                          teksUtama: _teksUtama,
                                          teksSamar: _teksSamar,
                                        ),
                                        const SizedBox(height: 16),
                                        if (_sedangMemuatGemini)
                                          const _KartuMemuat(
                                            pesan:
                                                'AI lagi mikirin solusinya... 🌱',
                                          )
                                        else if (_rekomendasiGemini.isNotEmpty)
                                          _KartuSaranAI(
                                            teks: _rekomendasiGemini,
                                            warnaPrimer: _primer,
                                            teksUtama: _teksUtama,
                                          ),
                                      ],
                                    )
                                  : _image != null
                                      ? Container(
                                          key: const ValueKey('gagal'),
                                          padding: const EdgeInsets.all(18),
                                          decoration: BoxDecoration(
                                            color: Colors.red.shade50,
                                            borderRadius:
                                                BorderRadius.circular(18),
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(Icons.error_outline,
                                                  color: Colors.red.shade400),
                                              const SizedBox(width: 10),
                                              const Expanded(
                                                child: Text(
                                                  "Waduh, daunnya nggak kebaca. Coba foto ulang dengan pencahayaan yang lebih terang ya.",
                                                  style: TextStyle(
                                                      color: Colors.black87),
                                                ),
                                              ),
                                            ],
                                          ),
                                        )
                                      : const SizedBox(key: ValueKey('kosong')),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // --- TOMBOL AKSI ---
                  Row(
                    children: [
                      Expanded(
                        child: _TombolAksi(
                          label: 'Kamera',
                          icon: Icons.camera_alt_rounded,
                          warna: _primer,
                          onTap: () => _ambilGambar(ImageSource.camera),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: _TombolAksi(
                          label: 'Galeri',
                          icon: Icons.photo_library_rounded,
                          warna: _primerGelap,
                          onTap: () => _ambilGambar(ImageSource.gallery),
                        ),
                      ),
                    ],
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _tampilkanPilihanSumber(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded, color: _primer),
              title: const Text('Ambil dari Kamera'),
              onTap: () {
                Navigator.pop(ctx);
                _ambilGambar(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, color: _primer),
              title: const Text('Pilih dari Galeri'),
              onTap: () {
                Navigator.pop(ctx);
                _ambilGambar(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ============== WIDGET-WIDGET KECIL (biar build() lebih rapi) ==============

class _ChipStatusModel extends StatelessWidget {
  final bool siap;
  const _ChipStatusModel({required this.siap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: siap ? Colors.lightGreenAccent : Colors.orangeAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            siap ? 'Siap' : 'Loading',
            style: const TextStyle(color: Colors.white, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _KartuFoto extends StatelessWidget {
  final File? image;
  final VoidCallback? onTap;
  const _KartuFoto({required this.image, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 240,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: image == null
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF6EE),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.add_a_photo_rounded,
                        size: 34, color: Color(0xFF1FA45C)),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    "Yuk, foto daun tomatnya",
                    style: TextStyle(
                      color: Color(0xFF1B2420),
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Ketuk di sini untuk mulai",
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                  ),
                ],
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.file(image!, fit: BoxFit.cover),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh_rounded,
                              size: 15, color: Colors.white),
                          SizedBox(width: 4),
                          Text('Ganti foto',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _KartuMemuat extends StatelessWidget {
  final String pesan;
  const _KartuMemuat({super.key, required this.pesan});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              color: Color(0xFF1FA45C),
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            pesan,
            style: const TextStyle(
              color: Color(0xFF6B7A70),
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _KartuHasil extends StatelessWidget {
  final bool isSehat;
  final String namaTampilan;
  final double akurasi;
  final Color warnaPrimer;
  final Color warnaWarning;
  final Color teksUtama;
  final Color teksSamar;

  const _KartuHasil({
    required this.isSehat,
    required this.namaTampilan,
    required this.akurasi,
    required this.warnaPrimer,
    required this.warnaWarning,
    required this.teksUtama,
    required this.teksSamar,
  });

  @override
  Widget build(BuildContext context) {
    final Color warnaAksen = isSehat ? warnaPrimer : warnaWarning;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Badge status pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: warnaAksen.withOpacity(0.12),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isSehat ? Icons.check_circle_rounded : Icons.warning_rounded,
                  size: 15,
                  color: warnaAksen,
                ),
                const SizedBox(width: 5),
                Text(
                  isSehat ? 'SEHAT' : 'PERLU PERHATIAN',
                  style: TextStyle(
                    color: warnaAksen,
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            namaTampilan,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: teksUtama,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Tingkat keyakinan AI',
                  style: TextStyle(fontSize: 12.5, color: teksSamar)),
              Text(
                "${(akurasi * 100).toStringAsFixed(0)}%",
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: warnaAksen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: akurasi,
              backgroundColor: warnaAksen.withOpacity(0.12),
              color: warnaAksen,
              minHeight: 8,
            ),
          ),
        ],
      ),
    );
  }
}

/// Menampilkan saran dari Gemini dalam bentuk beberapa *bubble* kartu
/// terpisah (bukan satu blok teks panjang), dipecah otomatis berdasarkan
/// penomoran "1.", "2.", "3." dari respons AI.
///
/// Lihat [_pisahkanPoin] untuk logika pemecahan & pembersihan markdown.
class _KartuSaranAI extends StatelessWidget {
  final String teks;
  final Color warnaPrimer;
  final Color teksUtama;

  const _KartuSaranAI({
    required this.teks,
    required this.warnaPrimer,
    required this.teksUtama,
  });

  // Judul & ikon default untuk 3 poin yang selalu kita minta ke Gemini:
  // 1) penyebab, 2) tindakan segera, 3) pencegahan/pengobatan.
  // Kalau Gemini balikin poin lebih/kurang dari 3, sisanya tetap ditampilkan
  // dengan judul & ikon generik supaya tidak error.
  static const List<_GayaBubble> _gayaBubble = [
    _GayaBubble(
      judul: 'Kenapa Ini Bisa Terjadi',
      ikon: Icons.search_rounded,
      warna: Color(0xFF6366F1), // indigo
    ),
    _GayaBubble(
      judul: 'Yang Harus Dilakukan Sekarang',
      ikon: Icons.bolt_rounded,
      warna: Color(0xFFF59E0B), // amber
    ),
    _GayaBubble(
      judul: 'Cara Mencegah & Mengobati',
      ikon: Icons.eco_rounded,
      warna: Color(0xFF1FA45C), // hijau
    ),
  ];
  static const _GayaBubble _gayaDefault = _GayaBubble(
    judul: 'Info Tambahan',
    ikon: Icons.info_rounded,
    warna: Color(0xFF64748B), // slate
  );

  // Memecah teks jadi list poin berdasarkan penomoran "1.", "2.", dst,
  // lalu membersihkan markdown (**bold**, bullet "- "/"* ") jadi teks polos.
  List<String> _pisahkanPoin(String mentah) {
    final potongan = mentah
        .split(RegExp(r'\n?\s*\d+\.\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    if (potongan.isEmpty) return [mentah.trim()];

    return potongan.map((poin) {
      String bersih = poin.replaceAll('**', '');
      bersih = bersih.replaceAllMapped(
        RegExp(r'(?:^|\n)\s*[-*]\s+', multiLine: true),
        (m) => '\n• ',
      );
      return bersih.trim();
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final poinPoin = _pisahkanPoin(teks);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 16, color: warnaPrimer),
              const SizedBox(width: 6),
              Text(
                "Saran dari AI",
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: warnaPrimer,
                ),
              ),
            ],
          ),
        ),
        for (int i = 0; i < poinPoin.length; i++) ...[
          _BubbleSaran(
            gaya: i < _gayaBubble.length ? _gayaBubble[i] : _gayaDefault,
            isi: poinPoin[i],
            teksUtama: teksUtama,
          ),
          if (i != poinPoin.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _GayaBubble {
  final String judul;
  final IconData ikon;
  final Color warna;
  const _GayaBubble(
      {required this.judul, required this.ikon, required this.warna});
}

class _BubbleSaran extends StatelessWidget {
  final _GayaBubble gaya;
  final String isi;
  final Color teksUtama;

  const _BubbleSaran({
    required this.gaya,
    required this.isi,
    required this.teksUtama,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: gaya.warna.withOpacity(0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: gaya.warna.withOpacity(0.18), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: gaya.warna,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(gaya.ikon, color: Colors.white, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  gaya.judul,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: gaya.warna,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            isi,
            style: TextStyle(
              fontSize: 13.8,
              color: teksUtama,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

class _TombolAksi extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color warna;
  final VoidCallback onTap;

  const _TombolAksi({
    required this.label,
    required this.icon,
    required this.warna,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: warna,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 19),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
