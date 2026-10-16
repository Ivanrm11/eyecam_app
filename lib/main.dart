import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } on CameraException catch (e) {
    print('Error con las cámaras: $e');
  }
  runApp(const MiAppAccesible());
}

class MiAppAccesible extends StatelessWidget {
  const MiAppAccesible({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EyeCam',
      theme: ThemeData.dark(),
      home: const PantallaPrincipal(),
    );
  }
}

class PantallaPrincipal extends StatefulWidget {
  const PantallaPrincipal({super.key});

  @override
  State<PantallaPrincipal> createState() => _PantallaPrincipalState();
}

class _PantallaPrincipalState extends State<PantallaPrincipal> {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();

  // URL de tu backend desplegado en Render (funciona desde cualquier sitio,
  // no hace falta estar en la misma WiFi que ningún ordenador).
  static const String _urlServidorIA = 'https://backend-accesibilidad.onrender.com/describir';

  // IA de texto (ya la tenías)
  final _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  bool _isProcessing = false;

  // --- Modelos CNN propios: RESPALDO cuando no hay conexión a internet ---
  Interpreter? _interpreterSenales;
  List<String> _clasesSenales = [];

  Interpreter? _interpreterSemaforo;
  static const List<String> _clasesSemaforo = ['rojo', 'ámbar', 'verde']; // mismo orden que en Colab
  static const int _tamanoImagenModelo = 48; // debe coincidir con IMG_SIZE del entrenamiento

  // Umbrales del RESPALDO local. Ajustados para hablar con la misma soltura
  // que el respaldo anterior (ML Kit), pero usando nuestras CNN propias.
  static const double _umbralConfianza = 0.50;
  static const double _margenMinimo = 0.10;
  static const double _umbralSemaforo = 0.60;
  static const double _margenSemaforo = 0.15;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _saludarUsuario();
    _despertarServidor();
    _cargarModeloSenales();
    _cargarModeloSemaforo();
  }

  // Carga el modelo CNN propio de señales (.tflite) y la lista de clases.
  Future<void> _cargarModeloSenales() async {
    try {
      _interpreterSenales = await Interpreter.fromAsset(
        'assets/models/modelo_senales.tflite',
      );
      final texto = await rootBundle.loadString('assets/models/clases.txt');
      _clasesSenales = texto.split('\n').where((l) => l.trim().isNotEmpty).toList();
      print('Modelo de señales cargado correctamente (${_clasesSenales.length} clases).');
    } catch (e) {
      print('No se pudo cargar el modelo de señales: $e');
    }
  }

  // Carga el segundo modelo, dedicado solo a reconocer el color del semáforo.
  Future<void> _cargarModeloSemaforo() async {
    try {
      _interpreterSemaforo = await Interpreter.fromAsset(
        'assets/models/modelo_semaforo.tflite',
      );
      print('Modelo de color de semáforo cargado correctamente.');
    } catch (e) {
      print('No se pudo cargar el modelo de color de semáforo: $e');
    }
  }

  // Manda una petición ligera al servidor nada más abrir la app, para que
  // Render empiece a "despertarlo" mientras el usuario todavía está mirando
  // la pantalla de carga, en vez de esperar a que pulse el botón.
  void _despertarServidor() async {
    try {
      final urlPing = _urlServidorIA.replaceFirst('/describir', '/ping');
      await http.get(Uri.parse(urlPing)).timeout(const Duration(seconds: 40));
      print('Servidor despertado correctamente.');
    } catch (e) {
      print('No se pudo despertar el servidor al abrir la app: $e');
    }
  }

  void _initCamera() {
    if (cameras.isEmpty) return;
    _controller = CameraController(cameras[0], ResolutionPreset.high);
    _controller!.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  void _saludarUsuario() async {
    await _tts.setLanguage("es-ES");
    await _tts.speak(
      "Aplicación lista. Pulsa el botón de la izquierda para leer texto, "
      "o el botón de la derecha para describir lo que hay alrededor.",
    );
  }

  // IA de texto (ya la tenías, sin cambios de lógica)
  void _procesarEntornoTexto() async {
    if (_controller == null || !_controller!.value.isInitialized || _isProcessing) return;

    setState(() => _isProcessing = true);
    await _tts.speak("Analizando texto...");

    try {
      final XFile image = await _controller!.takePicture();
      final InputImage inputImage = InputImage.fromFilePath(image.path);
      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);

      if (recognizedText.text.trim().isEmpty) {
        await _tts.speak("No he detectado ningún texto claro. Inténtalo de nuevo.");
      } else {
        print("Texto detectado: ${recognizedText.text}");
        await _tts.speak("He leído lo siguiente: ${recognizedText.text}");
      }
    } catch (e) {
      await _tts.speak("Error al procesar la imagen.");
      print(e);
    }

    setState(() => _isProcessing = false);
  }

  // Descripción de entorno robusta.
  // 1º intenta la IA en la nube (Gemini, entiende señales, aceras, escaleras, puertas... en contexto real).
  // 2º si no hay conexión o falla el servidor, cae a nuestras CNN propias como respaldo.
  // Si no hay nada relevante que decir, la app se queda en SILENCIO.
  void _describirEntorno() async {
    if (_controller == null || !_controller!.value.isInitialized || _isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final XFile image = await _controller!.takePicture();

      final String? descripcionNube = await _consultarIaNube(image);

      if (descripcionNube != null) {
        // Se pudo contactar con el servidor: confiamos en su respuesta.
        if (descripcionNube.isNotEmpty) {
          await _tts.speak(descripcionNube);
        }
        // Si vino vacío (la IA dijo "NADA"), no decimos nada. Silencio correcto.
      } else {
        // Sin conexión / servidor caído: usamos nuestras CNN propias como respaldo.
        await _describirEntornoLocal(image);
      }
    } catch (e) {
      print('Error al describir el entorno: $e');
      // No hablamos nada al usuario si algo falla técnicamente: mejor silencio que un error confuso.
    }

    setState(() => _isProcessing = false);
  }

  // Devuelve: la frase en español si la IA vio algo relevante,
  //           '' (vacío) si la IA miró la foto y no vio nada relevante,
  //           null si no se pudo contactar con el servidor (para activar el respaldo local).
  Future<String?> _consultarIaNube(XFile image) async {
    try {
      final bytes = await image.readAsBytes();
      final String base64Image = base64Encode(bytes);

      final response = await http
          .post(
            Uri.parse(_urlServidorIA),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'image': base64Image}),
          )
          .timeout(const Duration(seconds: 40));

      if (response.statusCode != 200) {
        print('El servidor de IA respondió con error ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body);
      final String texto = (data['descripcion'] as String).trim();

      print('IA en la nube dice: $texto');
      return texto.toUpperCase() == 'NADA' ? '' : texto;
    } catch (e) {
      print('IA en la nube no disponible, se usará el respaldo local: $e');
      return null;
    }
  }

  // Respaldo local sin conexión: usa nuestras CNN propias (señales + semáforo).
  Future<void> _describirEntornoLocal(XFile image) async {
    if (_interpreterSenales == null || _clasesSenales.isEmpty) {
      print('El modelo local de señales todavía no está cargado.');
      return;
    }

    final bytes = await image.readAsBytes();
    final img.Image? imagen = img.decodeImage(bytes);
    if (imagen == null) {
      print('No se pudo decodificar la foto.');
      return;
    }

    // RECORTE CENTRAL: asumimos que el usuario apunta más o menos centrado
    // a lo que quiere identificar (semáforo o señal).
    const double porcentajeRecorte = 0.55;
    final int ladoRecorte = imagen.width < imagen.height ? imagen.width : imagen.height;
    final int tamanoRecorte = (ladoRecorte * porcentajeRecorte).round();
    final int x = (imagen.width - tamanoRecorte) ~/ 2;
    final int y = (imagen.height - tamanoRecorte) ~/ 2;
    final img.Image recortada = img.copyCrop(imagen, x: x, y: y, width: tamanoRecorte, height: tamanoRecorte);

    // PRIORIDAD 1: la CNN de señales (más fiable que la de semáforo, que no
    // sabe decir "esto no es un semáforo").
    final resultado = _clasificarSenal(recortada);

    if (resultado != null) {
      final String etiqueta = resultado['etiqueta'] as String;
      final double confianza = resultado['confianza'] as double;
      print('CNN local detecta: $etiqueta (confianza ${(confianza * 100).toStringAsFixed(1)}%)');
      await _tts.speak('Señal de $etiqueta.');
      return;
    }

    // PRIORIDAD 2: si la CNN de señales no reconoce nada con garantías,
    // probamos si es un semáforo encendido (con umbral y margen exigentes).
    if (_hayLuzDeSemaforo(recortada) && _interpreterSemaforo != null) {
      final String? colorSemaforo = _clasificarColorSemaforo(recortada);
      if (colorSemaforo != null) {
        print('CNN local detecta semáforo: $colorSemaforo');
        await _tts.speak('Semáforo en $colorSemaforo.');
        return;
      }
    }

    // Si ninguno de los dos modelos reconoce nada con garantías: SILENCIO.
    print('Respaldo local: nada reconocido con suficiente confianza. Silencio.');
  }

  // Preprocesa el recorte exactamente igual que en el entrenamiento (mismo
  // tamaño y normalización) y ejecuta la CNN. Devuelve null si la confianza es baja.
  Map<String, Object>? _clasificarSenal(img.Image recortada) {
    final img.Image redimensionada = img.copyResize(
      recortada,
      width: _tamanoImagenModelo,
      height: _tamanoImagenModelo,
    );

    final input = List.generate(
      1,
      (_) => List.generate(
        _tamanoImagenModelo,
        (y) => List.generate(
          _tamanoImagenModelo,
          (x) {
            final pixel = redimensionada.getPixel(x, y);
            return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
          },
        ),
      ),
    );

    final output = List.filled(1 * _clasesSenales.length, 0.0).reshape([1, _clasesSenales.length]);
    _interpreterSenales!.run(input, output);

    final List<double> probabilidades = List<double>.from(output[0]);
    final List<double> ordenadas = List<double>.from(probabilidades)..sort();
    final double mejor = ordenadas[ordenadas.length - 1];
    final double segunda = ordenadas[ordenadas.length - 2];
    final int indiceMax = probabilidades.indexOf(mejor);
    final double confianza = mejor;
    final double margen = mejor - segunda;

    print('DEBUG - Prediccion cruda: ${_clasesSenales[indiceMax]} '
        '(confianza ${(confianza * 100).toStringAsFixed(1)}%, margen ${(margen * 100).toStringAsFixed(1)}%)');

    if (confianza < _umbralConfianza) return null;
    if (margen < _margenMinimo) return null; // el modelo duda entre 2 opciones: mejor callarse

    final String etiqueta = _clasesSenales[indiceMax];

    // La clase "semáforo" de este dataset es en realidad una señal de
    // advertencia triangular, no un semáforo real - la ignoramos aquí.
    if (etiqueta == 'semáforo') return null;

    return {
      'etiqueta': etiqueta,
      'confianza': confianza,
    };
  }

  // Filtro RÁPIDO (no decide el color, solo si "hay algo que parece una luz
  // encendida"): cuenta píxeles brillantes y saturados en la imagen.
  bool _hayLuzDeSemaforo(img.Image recortada) {
    int pixelesBrillantes = 0;
    int totalPixeles = 0;

    for (int y = 0; y < recortada.height; y += 2) {
      for (int x = 0; x < recortada.width; x += 2) {
        final pixel = recortada.getPixel(x, y);
        final double r = pixel.r / 255.0;
        final double g = pixel.g / 255.0;
        final double b = pixel.b / 255.0;

        final double maxC = [r, g, b].reduce(max);
        final double minC = [r, g, b].reduce(min);
        final double valor = maxC;
        final double saturacion = maxC == 0 ? 0 : (maxC - minC) / maxC;

        totalPixeles++;
        if (valor >= 0.55 && saturacion >= 0.35) pixelesBrillantes++;
      }
    }

    if (totalPixeles == 0) return false;
    return pixelesBrillantes >= 15;
  }

  // Usa la CNN dedicada (entrenada con fotos reales de semáforos) para
  // decidir el color exacto. Devuelve null si no está lo bastante segura.
  String? _clasificarColorSemaforo(img.Image recortada) {
    if (_interpreterSemaforo == null) return null;

    const int tamanoModeloSemaforo = 32; // debe coincidir con IMG_SIZE del notebook del semáforo
    final img.Image redimensionada = img.copyResize(
      recortada,
      width: tamanoModeloSemaforo,
      height: tamanoModeloSemaforo,
    );

    final input = List.generate(
      1,
      (_) => List.generate(
        tamanoModeloSemaforo,
        (y) => List.generate(
          tamanoModeloSemaforo,
          (x) {
            final pixel = redimensionada.getPixel(x, y);
            return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
          },
        ),
      ),
    );

    final output = List.filled(1 * _clasesSemaforo.length, 0.0).reshape([1, _clasesSemaforo.length]);
    _interpreterSemaforo!.run(input, output);

    final List<double> probabilidades = List<double>.from(output[0]);
    final List<double> ordenadas = List<double>.from(probabilidades)..sort();
    final double mejor = ordenadas[ordenadas.length - 1];
    final double segunda = ordenadas[ordenadas.length - 2];
    final int indiceMax = probabilidades.indexOf(mejor);
    final double confianza = mejor;
    final double margen = mejor - segunda;

    print('DEBUG - CNN semáforo: ${_clasesSemaforo[indiceMax]} '
        '(confianza ${(confianza * 100).toStringAsFixed(1)}%, margen ${(margen * 100).toStringAsFixed(1)}%)');

    if (confianza < _umbralSemaforo) return null;
    if (margen < _margenSemaforo) return null;

    return _clasesSemaforo[indiceMax];
  }

  @override
  void dispose() {
    _controller?.dispose();
    _textRecognizer.close();
    _interpreterSenales?.close();
    _interpreterSemaforo?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Color(0xFF0F1420),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF78D2FF)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // La cámara ocupa TODA la pantalla, de borde a borde,
          // recortando lo que sobre para llenar el hueco sin deformar la imagen.
          Positioned.fill(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller!.value.previewSize!.height,
                height: _controller!.value.previewSize!.width,
                child: CameraPreview(_controller!),
              ),
            ),
          ),

          // Sombra sutil arriba, para que si en el futuro se añade algún texto
          // de estado, se lea bien sobre la imagen de la cámara.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 90,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withOpacity(0.45), Colors.transparent],
                ),
              ),
            ),
          ),

          // Barra de botones flotante, semitransparente, sobre la cámara.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F1420).withOpacity(0.80),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.4),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _botonAccion(
                          icono: Icons.text_fields_rounded,
                          etiqueta: 'IZQUIERDA\nLEER TEXTO',
                          color: const Color(0xFFFFC107),
                          onPressed: _procesarEntornoTexto,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _botonAccion(
                          icono: Icons.remove_red_eye_rounded,
                          etiqueta: 'DERECHA\nDESCRIBIR ENTORNO',
                          color: const Color(0xFF78D2FF),
                          onPressed: _describirEntorno,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Botón de acción con icono + texto, estilo consistente para toda la app.
  Widget _botonAccion({
    required IconData icono,
    required String etiqueta,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: _isProcessing ? const Color(0xFF3A3F4B) : color,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 0,
      ),
      onPressed: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, size: 34),
          const SizedBox(height: 6),
          Text(
            etiqueta,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              height: 1.25,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}