# Google ML Kit Text Recognition incluye soporte opcional para varios idiomas
# (chino, japones, coreano, devanagari). Esta app solo usa TextRecognitionScript.latin,
# asi que le decimos a R8 que ignore esas clases que no estan presentes.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
