import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart'; // Keep for ChangeNotifier if used elsewhere
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart'; // Use secure storage
import 'package:logger/logger.dart'; // Use logger
import 'package:xml/xml.dart'; // Use for KML validation

// Initialize logger (you can customize the printer)
final logger = Logger(
  printer: PrettyPrinter(
    methodCount: 1, // number of method calls to be displayed
    errorMethodCount: 8, // number of method calls if stacktrace is provided
    lineLength: 120, // width of the output
    colors: true, // Colorful log messages
    printEmojis: true, // Print an emoji for each log message
    printTime: false // Should each log print contain a timestamp
  ),
);

// --- Custom Exceptions ---
class LlmException implements Exception {
  final String message;
  final dynamic underlyingError;
  LlmException(this.message, {this.underlyingError});

  @override
  String toString() => 'LlmException: $message ${underlyingError ?? ''}';
}

class KmlGenerationException extends LlmException {
  KmlGenerationException(super.message, {super.underlyingError});
  @override String toString() => 'KmlGenerationException: $message ${underlyingError ?? ''}';
}

class KmlValidationException extends LlmException {
  KmlValidationException(super.message, {super.underlyingError});
   @override String toString() => 'KmlValidationException: $message ${underlyingError ?? ''}';
}

class IntentClassificationException extends LlmException {
  IntentClassificationException(super.message, {super.underlyingError});
   @override String toString() => 'IntentClassificationException: $message ${underlyingError ?? ''}';
}

class ApiKeyException extends LlmException {
  ApiKeyException(super.message, {super.underlyingError});
   @override String toString() => 'ApiKeyException: $message ${underlyingError ?? ''}';
}

/// Enum for representing different LLM providers
enum LlmProvider {
  nvidia,
  groq,
  gemini,
}

/// Content class to represent input for the model (No changes)
class Content {
  final String role;
  final String text;

  Content._({required this.role, required this.text});

  static Content system(String text) => Content._(role: 'system', text: text);
  static Content user(String text) => Content._(role: 'user', text: text);
  static Content assistant(String text) => Content._(role: 'assistant', text: text);

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': text,
  };

  Map<String, dynamic> toGeminiJson() => {
    'role': role,
    'parts': [{'text': text}]
  };
}

/// Generation config for controlling model parameters (No changes)
class GenerationConfig {
  final double temperature;
  final double topP;
  final int maxOutputTokens;
  final bool stream;

  GenerationConfig({
    this.temperature = 0.7,
    this.topP = 0.95,
    this.maxOutputTokens = 1024,
    this.stream = false,
  });

  Map<String, dynamic> toJson() => {
    'temperature': temperature, 'top_p': topP, 'max_tokens': maxOutputTokens, 'stream': stream,
  };

  Map<String, dynamic> toGeminiJson() => {
    'temperature': temperature, 'topP': topP, 'maxOutputTokens': maxOutputTokens,
  };
}

/// Response class to represent output from the model (No changes)
class GeneratedContent {
  final String text;
  final bool isComplete;
  final Map<String, dynamic>? rawResponse; // Keep raw for debugging

  GeneratedContent({
    required this.text,
    this.isComplete = true,
    this.rawResponse,
  });
}

/// Abstract base class for LLM clients (Removed chat method)
abstract class BaseLlmClient {
  final String apiKey;
  final String baseUrl;
  final String modelName;
  final Duration timeoutDuration;

  BaseLlmClient({
    required this.apiKey,
    required this.baseUrl,
    required this.modelName,
    this.timeoutDuration = const Duration(seconds: 90), // Default timeout
  });

  /// Generate content with the model
  Future<GeneratedContent> generateContent(
    List<Content> contents, {
    GenerationConfig? config,
  });

  /// Generate content with streaming
  Stream<GeneratedContent> generateContentStream(
    List<Content> contents, {
    GenerationConfig? config,
  });
}

/// NVIDIA AI client implementation
class NvidiaLlmClient extends BaseLlmClient {
  NvidiaLlmClient({
    required super.apiKey,
    required super.modelName,
    super.baseUrl = 'https://integrate.api.nvidia.com/v1',
    super.timeoutDuration,
  });

  @override
  Future<GeneratedContent> generateContent(
    List<Content> contents, {
    GenerationConfig? config,
  }) async {
    final effectiveConfig = config ?? GenerationConfig();
    final Uri uri = Uri.parse('$baseUrl/chat/completions');
    final Map<String, dynamic> body = {
      'model': modelName,
      'messages': contents.map((e) => e.toJson()).toList(),
      ...effectiveConfig.toJson(),
      'stream': false,
    };

    logger.d('NVIDIA Request Body: ${json.encode(body)}');

    try {
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: json.encode(body),
      ).timeout(timeoutDuration); // Added timeout

      logger.d('NVIDIA Response Status: ${response.statusCode}');
      // logger.v('NVIDIA Response Body: ${response.body}'); // Verbose logging

      if (response.statusCode != 200) {
         logger.e('NVIDIA Error (${response.statusCode}): ${response.body}');
        throw LlmException('Failed to generate content: ${response.statusCode}', underlyingError: response.body);
      }

      final Map<String, dynamic> data = json.decode(utf8.decode(response.bodyBytes));
      String responseText = '';

      if (data.containsKey('choices') &&
          data['choices'] is List &&
          data['choices'].isNotEmpty &&
          data['choices'][0].containsKey('message') &&
          data['choices'][0]['message'].containsKey('content')) {
        responseText = data['choices'][0]['message']['content'] ?? '';
         logger.d('NVIDIA Response Text extracted successfully.');
      } else {
         logger.w('NVIDIA Response missing expected content structure: $data');
         // Optionally throw here if content is mandatory
      }

      return GeneratedContent(
        text: responseText,
        rawResponse: data,
      );
    } on TimeoutException catch (e, s) {
        logger.e('NVIDIA generateContent request timed out', error: e, stackTrace: s);
        throw LlmException('Request timed out', underlyingError: e);
    } catch (e, s) {
      logger.e('NVIDIA generateContent failed', error: e, stackTrace: s);
      // Rethrow as specific exception or handle
      throw LlmException('Failed during content generation', underlyingError: e);
    }
  }

  @override
  Stream<GeneratedContent> generateContentStream(
    List<Content> contents, {
    GenerationConfig? config,
  }) async* {
    final effectiveConfig = config ?? GenerationConfig();
    final Uri uri = Uri.parse('$baseUrl/chat/completions');
    final Map<String, dynamic> body = {
      'model': modelName,
      'messages': contents.map((e) => e.toJson()).toList(),
      ...effectiveConfig.toJson(),
      'stream': true,
    };

    final request = http.Request('POST', uri)
      ..headers.addAll({
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream', // Important for SSE
      })
      ..body = json.encode(body);

    logger.d('NVIDIA Streaming Request to $uri');
    http.StreamedResponse? streamedResponse;

    try {
      streamedResponse = await request.send().timeout(timeoutDuration); // Added timeout

      logger.d('NVIDIA Stream Response Status: ${streamedResponse.statusCode}');

      if (streamedResponse.statusCode != 200) {
        final response = await http.Response.fromStream(streamedResponse);
        logger.e('NVIDIA Stream Error (${response.statusCode}): ${response.body}');
        throw LlmException('Failed to initiate stream: ${response.statusCode}', underlyingError: response.body);
      }

      String accumulatedText = '';
      String residualData = ''; // Buffer for incomplete lines (SSE robustness)

      // Process the stream
      await for (final chunkBytes
          in streamedResponse.stream.timeout(timeoutDuration)) { // Timeout on inactivity
        final chunk = residualData + utf8.decode(chunkBytes, allowMalformed: true);
        final lines = chunk.split('\n');
        residualData = lines.removeLast(); // Keep potentially incomplete last line

        for (final line in lines) {
          if (line.isEmpty) continue;
          logger.v('NVIDIA Stream Line: $line'); // Verbose logging

          if (line == 'data: [DONE]') {
             logger.d('NVIDIA Stream received [DONE] marker.');
            yield GeneratedContent(text: accumulatedText, isComplete: true);
            return; // End the stream
          }

          if (line.startsWith('data: ')) {
            final jsonData = line.substring(6);
            if (jsonData.isEmpty) continue;

            try {
              final Map<String, dynamic> data = json.decode(jsonData);

              if (data.containsKey('choices') &&
                  data['choices'] is List &&
                  data['choices'].isNotEmpty) {
                final choice = data['choices'][0];
                String? deltaContent;

                if (choice.containsKey('delta') &&
                choice['delta'].containsKey('content') &&
                choice['delta']['content'] != null) {
              // Assign to a non-nullable local variable after null check
              final String deltaContent = choice['delta']['content'];
              accumulatedText += deltaContent; // Now safe to add
              yield GeneratedContent(
                text: accumulatedText,
                isComplete: false, // Still streaming
                rawResponse: data,
              );
            }
                 // Check for finish reason (optional)
                 if (choice.containsKey('finish_reason') && choice['finish_reason'] != null) {
                    logger.d('NVIDIA Stream finish reason: ${choice['finish_reason']}');
                 }
              }
            } on FormatException catch (e) {
               // Catch JSON decoding errors for this specific chunk
               logger.w('NVIDIA Stream - Failed to decode JSON chunk: "$jsonData"', error: e);
               // Decide whether to continue or yield an error/stop
               continue; // Skip malformed chunk
            }
          }
        }
      } // End of stream processing loop

      // If loop finishes without [DONE], yield final content
      logger.d('NVIDIA Stream finished without [DONE] marker. Yielding final content.');
      yield GeneratedContent(text: accumulatedText, isComplete: true);

    } on TimeoutException catch (e, s) {
        logger.e('NVIDIA generateContentStream request or stream timed out', error: e, stackTrace: s);
        throw LlmException('Stream timed out', underlyingError: e);
    } catch (e, s) {
      logger.e('NVIDIA generateContentStream failed', error: e, stackTrace: s);
      throw LlmException('Failed during stream processing', underlyingError: e);
    }
  }
}

/// Groq client implementation (Largely identical to NVIDIA due to OpenAI compatibility)
class GroqLlmClient extends BaseLlmClient {
  GroqLlmClient({
    required super.apiKey,
    required super.modelName,
    super.baseUrl = 'https://api.groq.com/openai/v1',
    super.timeoutDuration,
  });

   @override
  Future<GeneratedContent> generateContent(
    List<Content> contents, {
    GenerationConfig? config,
  }) async {
    final effectiveConfig = config ?? GenerationConfig();
    final Uri uri = Uri.parse('$baseUrl/chat/completions');
    final Map<String, dynamic> body = {
      'model': modelName,
      'messages': contents.map((e) => e.toJson()).toList(),
      ...effectiveConfig.toJson(),
      'stream': false,
    };

    logger.d('Groq Request Body: ${json.encode(body)}');

    try {
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: json.encode(body),
      ).timeout(timeoutDuration);

      logger.d('Groq Response Status: ${response.statusCode}');

      if (response.statusCode != 200) {
         logger.e('Groq Error (${response.statusCode}): ${response.body}');
        throw LlmException('Failed to generate content: ${response.statusCode}', underlyingError: response.body);
      }

      final Map<String, dynamic> data = json.decode(utf8.decode(response.bodyBytes));
      String responseText = '';

      if (data.containsKey('choices') &&
          data['choices'] is List &&
          data['choices'].isNotEmpty &&
          data['choices'][0].containsKey('message') &&
          data['choices'][0]['message'].containsKey('content')) {
        responseText = data['choices'][0]['message']['content'] ?? '';
         logger.d('Groq Response Text extracted successfully.');
      } else {
         logger.w('Groq Response missing expected content structure: $data');
      }

      return GeneratedContent(
        text: responseText,
        rawResponse: data,
      );
    } on TimeoutException catch (e, s) {
        logger.e('Groq generateContent request timed out', error: e, stackTrace: s);
        throw LlmException('Request timed out', underlyingError: e);
    } catch (e, s) {
      logger.e('Groq generateContent failed', error: e, stackTrace: s);
      throw LlmException('Failed during content generation', underlyingError: e);
    }
  }

  @override
  Stream<GeneratedContent> generateContentStream(
    List<Content> contents, {
    GenerationConfig? config,
  }) async* {
    final effectiveConfig = config ?? GenerationConfig();
    final Uri uri = Uri.parse('$baseUrl/chat/completions');
    final Map<String, dynamic> body = {
      'model': modelName,
      'messages': contents.map((e) => e.toJson()).toList(),
      ...effectiveConfig.toJson(),
      'stream': true,
    };

    final request = http.Request('POST', uri)
      ..headers.addAll({
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      })
      ..body = json.encode(body);

    logger.d('Groq Streaming Request to $uri');
    http.StreamedResponse? streamedResponse;

    try {
      streamedResponse = await request.send().timeout(timeoutDuration);

      logger.d('Groq Stream Response Status: ${streamedResponse.statusCode}');

      if (streamedResponse.statusCode != 200) {
        final response = await http.Response.fromStream(streamedResponse);
         logger.e('Groq Stream Error (${response.statusCode}): ${response.body}');
        throw LlmException('Failed to initiate stream: ${response.statusCode}', underlyingError: response.body);
      }

      String accumulatedText = '';
      String residualData = ''; // Buffer for incomplete lines

      await for (final chunkBytes
          in streamedResponse.stream.timeout(timeoutDuration)) {
        final chunk = residualData + utf8.decode(chunkBytes, allowMalformed: true);
        final lines = chunk.split('\n');
        residualData = lines.removeLast();

        for (final line in lines) {
           if (line.isEmpty) continue;
           logger.v('Groq Stream Line: $line');

          if (line == 'data: [DONE]') {
             logger.d('Groq Stream received [DONE] marker.');
            yield GeneratedContent(text: accumulatedText, isComplete: true);
            return;
          }

          if (line.startsWith('data: ')) {
            final jsonData = line.substring(6);
            if (jsonData.isEmpty) continue;

            try {
              final Map<String, dynamic> data = json.decode(jsonData);

              if (data.containsKey('choices') &&
                  data['choices'] is List &&
                  data['choices'].isNotEmpty) {
                final choice = data['choices'][0];
                String? deltaContent;

                            // Inside GroqLlmClient.generateContentStream loop
            if (choice.containsKey('delta') &&
                choice['delta'].containsKey('content') &&
                choice['delta']['content'] != null) {
              // Assign to a non-nullable local variable after null check
              final String deltaContent = choice['delta']['content'];
              accumulatedText += deltaContent; // Now safe to add
              yield GeneratedContent(
                text: accumulatedText,
                isComplete: false,
                rawResponse: data,
              );
            }
                 if (choice.containsKey('finish_reason') && choice['finish_reason'] != null) {
                    logger.d('Groq Stream finish reason: ${choice['finish_reason']}');
                 }
              }
            } on FormatException catch (e) {
               logger.w('Groq Stream - Failed to decode JSON chunk: "$jsonData"', error: e);
               continue;
            }
          }
        }
      }

       logger.d('Groq Stream finished without [DONE] marker. Yielding final content.');
      yield GeneratedContent(text: accumulatedText, isComplete: true);

    } on TimeoutException catch (e, s) {
        logger.e('Groq generateContentStream request or stream timed out', error: e, stackTrace: s);
        throw LlmException('Stream timed out', underlyingError: e);
    } catch (e, s) {
      logger.e('Groq generateContentStream failed', error: e, stackTrace: s);
      throw LlmException('Failed during stream processing', underlyingError: e);
    }
  }
}

/// Gemini client implementation
class GeminiLlmClient extends BaseLlmClient {
  final String apiVersion;

  GeminiLlmClient({
    required super.apiKey,
    required super.modelName,
    super.baseUrl = 'https://generativelanguage.googleapis.com',
    this.apiVersion = 'v1beta', // Use v1beta for streaming, v1 otherwise
    super.timeoutDuration,
  });

  @override
  Future<GeneratedContent> generateContent(
    List<Content> contents, {
    GenerationConfig? config,
  }) async {
    final effectiveConfig = config ?? GenerationConfig();
    // Use v1 for non-streaming generateContent
    final Uri uri = Uri.parse('$baseUrl/v1/models/$modelName:generateContent?key=$apiKey');
    final geminiContents = contents.map((e) => e.toGeminiJson()).toList();
    final Map<String, dynamic> body = {
      'contents': geminiContents,
      'generationConfig': effectiveConfig.toGeminiJson(),
    };

     logger.d('Gemini Request Body: ${json.encode(body)}');

    try {
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode(body),
      ).timeout(timeoutDuration);

      logger.d('Gemini Response Status: ${response.statusCode}');

      if (response.statusCode != 200) {
        logger.e('Gemini Error (${response.statusCode}): ${response.body}');
        throw LlmException('Failed to generate content: ${response.statusCode}', underlyingError: response.body);
      }

      final Map<String, dynamic> data = json.decode(utf8.decode(response.bodyBytes));
      String responseText = '';

      // Simplified extraction for Gemini v1
      if (data.containsKey('candidates') &&
          data['candidates'] is List &&
          data['candidates'].isNotEmpty &&
          data['candidates'][0]['content']?['parts']?[0]?['text'] != null ) {
           responseText = data['candidates'][0]['content']['parts'][0]['text'];
           logger.d('Gemini Response Text extracted successfully.');
      } else {
         logger.w('Gemini Response missing expected content structure: $data');
      }

      return GeneratedContent(
        text: responseText,
        rawResponse: data,
      );
    } on TimeoutException catch (e, s) {
        logger.e('Gemini generateContent request timed out', error: e, stackTrace: s);
        throw LlmException('Request timed out', underlyingError: e);
    } catch (e, s) {
      logger.e('Gemini generateContent failed', error: e, stackTrace: s);
      throw LlmException('Failed during content generation', underlyingError: e);
    }
  }

  @override
  Stream<GeneratedContent> generateContentStream(
    List<Content> contents, {
    GenerationConfig? config,
  }) async* {
    final effectiveConfig = config ?? GenerationConfig();
    // Use v1beta for streaming
    final Uri uri = Uri.parse('$baseUrl/$apiVersion/models/$modelName:streamGenerateContent?key=$apiKey&alt=sse'); // Use alt=sse
    final geminiContents = contents.map((e) => e.toGeminiJson()).toList();
    final Map<String, dynamic> body = {
      'contents': geminiContents,
      'generationConfig': effectiveConfig.toGeminiJson(),
    };

    final request = http.Request('POST', uri)
      ..headers.addAll({'Content-Type': 'application/json'})
      ..body = json.encode(body);

     logger.d('Gemini Streaming Request to $uri');
     http.StreamedResponse? streamedResponse;

    try {
      streamedResponse = await request.send().timeout(timeoutDuration);

       logger.d('Gemini Stream Response Status: ${streamedResponse.statusCode}');

      if (streamedResponse.statusCode != 200) {
        final response = await http.Response.fromStream(streamedResponse);
        logger.e('Gemini Stream Error (${response.statusCode}): ${response.body}');
        throw LlmException('Failed to initiate stream: ${response.statusCode}', underlyingError: response.body);
      }

      String accumulatedText = '';
      String residualData = '';

      // *** IMPORTANT: Gemini SSE Stream Parsing ***
      // Gemini's SSE format might differ slightly. It often sends JSON objects directly
      // within the 'data: ' lines, not necessarily deltas like OpenAI.
      // The parsing below assumes finding text in candidates[0].content.parts[0].text
      // This might need adjustment based on actual responses.
      // More robust parsing might involve accumulating JSON chunks if they span multiple lines.
      // For now, we use the residual buffer approach which helps with fragmented lines.

      await for (final chunkBytes
          in streamedResponse.stream.timeout(timeoutDuration)) {
        final chunk = residualData + utf8.decode(chunkBytes, allowMalformed: true);
        final lines = chunk.split('\n');
        residualData = lines.removeLast();

        for (final line in lines) {
          if (line.isEmpty) continue;
          logger.v('Gemini Stream Line: $line');

          // Gemini SSE usually uses 'data: ' prefix
          if (line.startsWith('data: ')) {
             final jsonData = line.substring(6);
             if (jsonData.isEmpty) continue;

             try {
               final Map<String, dynamic> data = json.decode(jsonData);
               String? deltaText;

               // Extract text based on typical Gemini stream structure
               if (data.containsKey('candidates') &&
                   data['candidates'] is List &&
                   data['candidates'].isNotEmpty &&
                   data['candidates'][0]['content']?['parts']?[0]?['text'] != null )
               {
                   deltaText = data['candidates'][0]['content']['parts'][0]['text'];
               }

               if (deltaText != null && deltaText.isNotEmpty) {
                   // NOTE: Gemini might send the *full* text so far, or just the delta.
                   // Assuming it sends deltas or we want to accumulate:
                   accumulatedText += deltaText; // Adjust if Gemini sends full text always
                   yield GeneratedContent(
                     text: accumulatedText,
                     isComplete: false,
                     rawResponse: data,
                   );
               }
                // Check for finish reason (location may vary in Gemini response)
                final finishReason = data['candidates']?[0]?['finishReason'];
                if (finishReason != null) {
                   logger.d('Gemini Stream finish reason: $finishReason');
                   // If finish reason is 'STOP' or similar, the stream might be ending.
                }

             } on FormatException catch (e) {
                logger.w('Gemini Stream - Failed to decode JSON chunk: "$jsonData"', error: e);
                continue; // Skip malformed chunk
             }
          }
        }
      }

      logger.d('Gemini Stream finished. Yielding final content.');
      yield GeneratedContent(text: accumulatedText, isComplete: true);

    } on TimeoutException catch (e, s) {
        logger.e('Gemini generateContentStream request or stream timed out', error: e, stackTrace: s);
        throw LlmException('Stream timed out', underlyingError: e);
    } catch (e, s) {
      logger.e('Gemini generateContentStream failed', error: e, stackTrace: s);
      throw LlmException('Failed during stream processing', underlyingError: e);
    }
  }
}


/// Factory for creating LLM clients based on provider
class LlmClientFactory {
  static BaseLlmClient createClient({
    required LlmProvider provider,
    required String apiKey,
    required String modelName,
    Duration? timeout, // Optional timeout override
  }) {
    final effectiveTimeout = timeout ?? const Duration(seconds: 90);

    switch (provider) {
      case LlmProvider.nvidia:
        return NvidiaLlmClient(
          apiKey: apiKey,
          modelName: modelName,
          timeoutDuration: effectiveTimeout,
        );
      case LlmProvider.groq:
        return GroqLlmClient(
          apiKey: apiKey,
          modelName: modelName,
           timeoutDuration: effectiveTimeout,
        );
      case LlmProvider.gemini:
        return GeminiLlmClient(
          apiKey: apiKey,
          modelName: modelName,
           timeoutDuration: effectiveTimeout,
        );
    }
  }
}

/// KML Generator service using any LLM client
class KmlGeneratorService {
  final BaseLlmClient llm;
  // Logger passed in or created internally
  final Logger _log = logger; // Use the global logger instance

  static const String _kmlSystemPrompt = '''You are an expert KML generation assistant for Liquid Galaxy. Your sole purpose is to generate valid KML 2.2 XML code based on user requests, strictly adhering to the KML standard and the requirements below.

**Output Requirements:**

1.  **KML Only:** Respond ONLY with the KML XML code. Your entire response must start directly with `<?xml version="1.0" encoding="UTF-8"?>` or `<kml ...>` and end precisely with `</kml>`. Do NOT include ```xml markdown, any conversational text, greetings, apologies, progress messages, or explanations outside of KML comment tags (`<!-- ... -->`) if absolutely necessary for clarity *within* the KML structure.

2.  **Smart Tour Generation (`<gx:Tour>`):**
    *   Analyze the *entire* user request. If the total number of unique locations, points of interest, or steps identified across the *whole* request is **greater than one**, OR if a sequence, route, or tour is explicitly requested, you **MUST** generate a single `<gx:Tour>` within the `<Document>`.
    *   This tour must contain a `<gx:Playlist>` with appropriate `<gx:FlyTo>` elements for *each* point of interest. Use smooth transitions (`<gx:flyToMode>smooth</gx:flyToMode>`) and reasonable `<gx:duration>`.
    *   Define suitable views within each `<gx:FlyTo>` using `<LookAt>` or `<Camera>`. Consider ground-level views (`tilt` near 90, low `altitude`, low `range`) for immersive experiences where appropriate (e.g., street scenes, building close-ups).
    *   **Crucially:** If a tour is generated, use `<gx:AnimatedUpdate>` within the playlist to dynamically show (`<gx:balloonVisibility>1</gx:balloonVisibility>`) and hide (`<gx:balloonVisibility>0</gx:balloonVisibility>`) the corresponding Placemark's balloon during the appropriate `<gx:Wait>` period. Reference the *Indore example* below for this pattern.
    *   If **only a single point** is requested or identified in the *entire* query, do **NOT** generate a `<gx:Tour>`. Instead, create a single `<Placemark>` and define a suitable default view using `<LookAt>` or `<Camera>` directly within the `<Document>`.

3.  **Rich, Good-Looking Balloons & Styling:**
    *   When details (descriptions, facts, weather, images, lists, etc.) are requested or contextually appropriate, create visually appealing and informative balloons using HTML within `CDATA`.
    *   **Recommended Method:** Place the rich HTML content (using divs, spans, inline CSS for styling, tables, lists, publicly accessible `<img>` tags) inside the `<Placemark><description><![CDATA[...]]></description>`. Then, in the associated `<Style>` or `<StyleMap>`, define a simple `<BalloonStyle>` that references this description: `<BalloonStyle><text>\$[description]</text></BalloonStyle>`. You can still set `<bgColor>` or other basic balloon properties here. *See the Indore example for this pattern.*
    *   **Alternative Method (Less Common):** For highly complex layouts where the entire balloon structure *is* the content, or if the `<description>` needs to remain plain, you *can* place the *full* HTML structure directly inside `<Style><BalloonStyle><text><![CDATA[...]]></text></BalloonStyle>`. *See the Paris example for this pattern.*
    *   **Avoid Conflicts:** Do *not* define a complex HTML structure within `<description>` *and* also define a separate, complex template using `%s` placeholders within `<BalloonStyle><text>`. Choose one primary method for balloon content rendering per style.
    *   Define reusable `<Style>` elements (with `<IconStyle>`, `<LabelStyle>`, `<LineStyle>`, `<PolyStyle>`, `<BalloonStyle>`) and `<StyleMap>` (for normal/highlight states) as needed. Use meaningful `id` attributes.

4.  **Placemarks:** Use `<Placemark>` for points of interest. Include `<name>`, the rich `<description>` (using CDATA for HTML as described above), `<styleUrl>`, and `<Point><coordinates>` (longitude,latitude[,altitude]). Ensure Placemarks have unique `id` attributes if they need to be targeted by `<gx:AnimatedUpdate>` in a tour.

5.  **Validity & Structure:** Ensure the output is well-formed XML and valid KML 2.2. Pay strict attention to closing tags, case sensitivity, and correct namespaces (`xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2"`). Place `<Style>`, `<StyleMap>`, and `<Schema>` elements before Placemarks and Folders within the `<Document>` where possible. Tours (`<gx:Tour>`) are typically placed after Styles/Placemarks within the `<Document>`.

**User Request Interpretation:**
*   Carefully parse the *entire* user prompt. Identify *all* requested locations, themes, or data points (e.g., "Top 3 indoor *and* Top 3 outdoor" means 6 locations total).
*   Ensure the generated KML addresses the *complete* request.
*   If specific coordinates or camera views are given, use them. Otherwise, determine suitable geographic coordinates and visually appropriate `<LookAt>` or `<Camera>` parameters (heading, tilt, range, altitude).

**Examples for Reference:**

*   **Paris Weather KML (Complex HTML in `<BalloonStyle><text>`):**
    ```kml
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
      <Document>
        <name>Paris Weather Example</name>
        <Style id="weatherIconStyle">
          <IconStyle> <Icon><href>http://maps.google.com/mapfiles/kml/weather/sunny.png</href></Icon> </IconStyle>
          <BalloonStyle>
            <bgColor>ffffffff</bgColor>
            <text>
              <![CDATA[
              <div style="font-family: 'Segoe UI', ... max-width: 450px;">
                <!-- Header -->
                <div style="background: linear-gradient(...); ...">
                  <h1 style="...">☀️ Weather in Paris 🇫🇷</h1> ...
                </div>
                <!-- Body -->
                <div style="padding: 20px; ...">
                  <!-- Current Conditions -->
                  <div style="text-align: center; ..."> ... <span style="font-size: 3.5em; ...">11°C</span> ... </div>
                  <!-- Details Table -->
                  <table style="width: 100%; ..."> ... </table>
                  <!-- Footer -->
                  <p style="text-align: center; ..."><i>Weather data...</i></p>
                </div>
              </div>
              ]]>
            </text>
          </BalloonStyle>
        </Style>
        <Placemark>
          <name>Paris Weather Now</name>
          <styleUrl>#weatherIconStyle</styleUrl>
          <Point> <coordinates>2.3522,48.8566,0</coordinates> </Point>
        </Placemark>
      </Document>
    </kml>
    ```

*   **Indore Food Tour KML (Tour with `<gx:AnimatedUpdate>`, Rich HTML in `<description>`, `\$[description]` in `<BalloonStyle>`):**
    ```kml
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
      <Document>
        <name>Indore Food Tour Example</name>
        <Style id="foodPlacemarkStyle">
          <IconStyle> <Icon><href>http://maps.google.com/mapfiles/kml/paddle/red-stars.png</href></Icon> </IconStyle>
          <BalloonStyle> <bgColor>ffffffff</bgColor> <text>\$[description]</text> </BalloonStyle> <!-- Uses Placemark's description -->
        </Style>
        <!-- ... potentially StyleMap ... -->
        <Folder>
            <name>Food Locations</name>
            <Placemark id="pm_sarafa"> <name>Sarafa Bazaar</name> <styleUrl>#foodPlacemark</styleUrl>
                <description><![CDATA[ <div style="..."><h1 style="...">🌙 Sarafa Bazaar</h1><p>...</p><ul><li>...</li></ul></div> ]]></description>
                <Point><coordinates>75.8575,22.7177,0</coordinates></Point>
            </Placemark>
            <!-- ... other placemarks ... -->
        </Folder>
        <gx:Tour>
          <name>Indore Food Tour (Ground Level)</name>
          <gx:Playlist>
            <gx:FlyTo> <gx:duration>5.0</gx:duration> <LookAt>...</LookAt> </gx:FlyTo>
            <gx:Wait><gx:duration>0.5</gx:duration></gx:Wait>
            <gx:FlyTo> <gx:duration>2.5</gx:duration> <LookAt>...</LookAt> <!-- Fly to ground level --> </gx:FlyTo>
            <!-- Show Balloon -->
            <gx:AnimatedUpdate> <Update> <targetHref/> <Change> <Placemark targetId="pm_sarafa"> <gx:balloonVisibility>1</gx:balloonVisibility> </Placemark> </Change> </Update> </gx:AnimatedUpdate>
            <gx:Wait> <gx:duration>12.0</gx:duration> </gx:Wait> <!-- Wait while balloon is visible -->
            <!-- Hide Balloon -->
            <gx:AnimatedUpdate> <Update> <targetHref/> <Change> <Placemark targetId="pm_sarafa"> <gx:balloonVisibility>0</gx:balloonVisibility> </Placemark> </Change> </Update> </gx:AnimatedUpdate>
            <gx:Wait> <gx:duration>0.5</gx:duration> </gx:Wait>
            <!-- ... FlyTo and updates for next placemark ... -->
          </gx:Playlist>
        </gx:Tour>
      </Document>
    </kml>
    ```
''';

  KmlGeneratorService({required this.llm});

  /// Generate KML from a user query
  Future<String> generateKml(String query) async {
     _log.i("Attempting to generate KML for query: '$query'");
    try {
      final response = await llm.generateContent([
        Content.system(_kmlSystemPrompt),
        Content.user(query),
      ]);

      final kmlContent = response.text.trim();

      if (kmlContent.isEmpty) {
         _log.w("KML Generation resulted in empty content.");
         throw KmlGenerationException("Received empty content from LLM for KML generation.");
      }

      // Validate KML
      _validateKml(kmlContent); // Throws KmlValidationException on failure

      _log.i("KML generated and validated successfully.");
      return kmlContent;

    } on LlmException catch (e) {
       _log.e("LLM error during KML generation", error: e, stackTrace: StackTrace.current);
       // Re-throw as a more specific exception if needed, or keep LlmException
       throw KmlGenerationException("LLM failed during KML generation", underlyingError: e);
    } catch (e, s) {
      // Catch potential validation errors or other unexpected issues
      _log.e("Unexpected error during KML generation/validation", error: e, stackTrace: s);
      // Throw a specific KML generation exception
       throw KmlGenerationException("Failed to generate or validate KML", underlyingError: e);
    }
  }

  /// Validate KML structure. Throws KmlValidationException if invalid.
    /// Validate KML structure. Throws KmlValidationException if invalid.
  void _validateKml(String kmlContent) {
     final trimmed = kmlContent.trim();
     if (!((trimmed.startsWith('<?xml') || trimmed.startsWith('<kml')) &&
             trimmed.endsWith('</kml>'))) {
        _log.w("KML Validation Failed: Doesn't start/end correctly.");
        throw KmlValidationException("KML content missing valid start/end tags.");
     }
     try {
        XmlDocument.parse(trimmed);
        _log.d("KML structure parsed successfully.");
     } on XmlException catch (e) {
        // REMOVED e.line / e.column from log message
        _log.w("KML Validation Failed: Invalid XML Structure - ${e.message}");
        // PASS e.toString() to underlyingError
        throw KmlValidationException("Invalid KML XML structure", underlyingError: e.toString());
     } catch (e, s) {
        _log.w("KML Validation Failed: Unexpected parsing error", error: e, stackTrace: s);
        // PASS e.toString() to underlyingError
        throw KmlValidationException("Unexpected error during KML validation", underlyingError: e.toString());
     }
  }


  /// Generate KML with streaming for progress updates
  /// Returns stream of KML text chunks. Throws exceptions on error.
  Stream<String> generateKmlStream(String query) async* {
    _log.i("Attempting to generate KML stream for query: '$query'");
    String accumulatedContent = '';

    try {
      await for (final chunk in llm.generateContentStream([
        Content.system(_kmlSystemPrompt),
        Content.user(query),
      ])) {
        accumulatedContent = chunk.text;
        yield accumulatedContent; // Yield the current accumulated text

        if (chunk.isComplete) {
           _log.i("KML Stream finished. Validating final content.");
           try {
              _validateKml(accumulatedContent); // Validate final content
               _log.i("Final KML stream content validated successfully.");
           } catch (validationError) {
               _log.w("Final KML stream content failed validation.", error: validationError);
               // Depending on desired behavior, you might:
               // 1. Stop the stream here.
               // 2. Yield an error marker (not standard for Stream<String>).
               // 3. Throw the validation error, stopping the stream consumer.
               throw validationError; // Rethrow validation error
           }
        }
      }
    } on LlmException catch (e) {
       _log.e("LLM error during KML stream generation", error: e, stackTrace: StackTrace.current);
       throw KmlGenerationException("LLM failed during KML stream generation", underlyingError: e);
    } catch (e, s) {
      _log.e("Unexpected error during KML stream", error: e, stackTrace: s);
       // Includes potential validation errors rethrown from the end of the stream
      if (e is KmlValidationException) {
        rethrow; // Preserve the specific validation error
      }
      throw KmlGenerationException("Failed during KML stream processing", underlyingError: e);
    }
  }
}


/// Intent classifier service for processing voice commands
class IntentClassifierService {
  final BaseLlmClient llm;
  final Logger _log = logger; // Use the global logger instance

  static const String _intentSystemPrompt = '''You are an assistant for controlling a Liquid Galaxy system, which is a large multi-screen map display. Your primary task is to analyze the user's request and determine their intent for interacting with this map display. Respond ONLY with a valid JSON object containing an 'intent' key (string) and optionally other parameters like 'query' (string for KML generation), 'location_name' (string), or 'lookAt' (string, KML LookAt format).

Possible intents are:
- GENERATE_KML: User wants to visualize something on the map (places, tours, data). This often involves locations, landmarks, routes, or descriptions of things to see.
- CLEAR_KML: User wants to remove the current visualization from the screens.
- CLEAR_LOGO: User wants to remove the corner logo.
- PLAY_TOUR: User wants to start or resume the animation/tour within the currently displayed KML.
- EXIT_TOUR: User wants to stop the animation/tour within the currently displayed KML.
- FLY_TO: User wants the map view to navigate directly to a specific named location or coordinate.
- REBOOT_LG: User wants to restart the Liquid Galaxy system (use with caution).
- UNKNOWN: The request is unclear, unrelated to map control, or cannot be mapped to the above intents.

CRITICAL: If the user asks to "show", "display", "visualize", "where is", "fly to", "tour of", or asks about locations/landmarks/destinations in a way that implies seeing them on the map, classify the intent as GENERATE_KML and formulate a concise 'query' parameter suitable for generating KML content for Liquid Galaxy. For direct commands like "clear screen", use the appropriate command intent (e.g., CLEAR_KML). If the request is purely conversational or unrelated (e.g., "tell me a joke", "what's the weather like *in general*"), use UNKNOWN.

Examples:
User: "Show me the Eiffel Tower" -> {"intent": "GENERATE_KML", "query": "Eiffel Tower"}
User: "Tell me top 3 tourist destinations in Paris" -> {"intent": "GENERATE_KML", "query": "Top 3 tourist destinations in Paris"}
User: "Create a tour of volcanoes in Hawaii" -> {"intent": "GENERATE_KML", "query": "Tour of volcanoes in Hawaii"}
User: "Fly to Mount Everest" -> {"intent": "FLY_TO", "location_name": "Mount Everest"}
User: "Clear the screen" -> {"intent": "CLEAR_KML"}
User: "Stop the tour" -> {"intent": "EXIT_TOUR"}
User: "Start the tour" -> {"intent": "PLAY_TOUR"}
User: "Tell me about Mars" -> {"intent": "UNKNOWN", "original_query": "Tell me about Mars"}
User: "Reboot the rig" -> {"intent": "UNKNOWN"}

Ensure the output is ONLY the JSON object, nothing else before or after.
''';

  IntentClassifierService({required this.llm});

  /// Classify a voice command into an intent with parameters.
  /// Returns a Map representing the JSON, or throws IntentClassificationException.
  Future<Map<String, dynamic>> classifyIntent(String voiceCommand) async {
     _log.i("Attempting to classify intent for command: '$voiceCommand'");
    try {
      final response = await llm.generateContent([
        Content.system(_intentSystemPrompt),
        Content.user(voiceCommand),
      ]);

      final jsonContent = response.text.trim();
       _log.d("Raw intent classification response: $jsonContent");

      if (jsonContent.isEmpty) {
         _log.w("Intent classification returned empty content.");
         throw IntentClassificationException("Received empty content from LLM for intent classification.");
      }

      Map<String, dynamic> intentData;
      try {
        intentData = json.decode(jsonContent);
      } on FormatException catch (e) {
         _log.e("Failed to parse intent JSON: '$jsonContent'", error: e);
         // Attempt to recover or return UNKNOWN
          throw IntentClassificationException("LLM returned invalid JSON for intent", underlyingError: {'rawResponse': jsonContent, 'error': e});
      }

      // --- Intent JSON Robustness Check ---
      if (intentData is Map && intentData.containsKey('intent') && intentData['intent'] is String) {
         _log.i("Intent classified successfully as: ${intentData['intent']}");
        return intentData;
      } else {
        _log.w("Intent JSON is valid but lacks 'intent' key or it's not a string. Data: $intentData");
        // Return UNKNOWN or throw, based on desired strictness
        return {
          'intent': 'UNKNOWN',
          'error': 'LLM response missing valid intent key.',
          'rawResponse': jsonContent,
          'parsedJson': intentData,
        };
         // OR: throw IntentClassificationException("LLM response missing valid intent key.", underlyingError: {'rawResponse': jsonContent, 'parsedJson': intentData});
      }

    } on LlmException catch (e) {
        _log.e("LLM error during intent classification", error: e, stackTrace: StackTrace.current);
        throw IntentClassificationException("LLM failed during intent classification", underlyingError: e);
    } catch (e, s) {
        _log.e("Unexpected error during intent classification", error: e, stackTrace: s);
        throw IntentClassificationException("Failed to classify intent", underlyingError: e);
    }
  }
}


/// API key manager using flutter_secure_storage
class ApiKeyManager {
  // Use FlutterSecureStorage
  final _secureStorage = const FlutterSecureStorage();
  final Logger _log = logger; // Use global logger

  static const String _nvidiaKeyPref = 'llm_nvidia_api_key';
  static const String _groqKeyPref = 'llm_groq_api_key';
  static const String _geminiKeyPref = 'llm_gemini_api_key';
  static const String _activeProviderPref = 'llm_active_provider_index';

  /// Save API key securely
  Future<void> saveApiKey(LlmProvider provider, String apiKey) async {
    String key;
    switch (provider) {
      case LlmProvider.nvidia: key = _nvidiaKeyPref; break;
      case LlmProvider.groq: key = _groqKeyPref; break;
      case LlmProvider.gemini: key = _geminiKeyPref; break;
    }
    try {
       await _secureStorage.write(key: key, value: apiKey);
       _log.i("API Key saved securely for provider: $provider");
    } catch (e, s) {
       _log.e("Failed to save API key for $provider", error: e, stackTrace: s);
       throw ApiKeyException("Failed to write API key to secure storage", underlyingError: e);
    }
  }

  /// Get API key securely
  Future<String?> getApiKey(LlmProvider provider) async {
    String key;
    switch (provider) {
      case LlmProvider.nvidia: key = _nvidiaKeyPref; break;
      case LlmProvider.groq: key = _groqKeyPref; break;
      case LlmProvider.gemini: key = _geminiKeyPref; break;
    }
    try {
       final apiKey = await _secureStorage.read(key: key);
       _log.d("Retrieved API Key for $provider: ${apiKey != null && apiKey.isNotEmpty ? 'Exists' : 'Not Found'}");
       return apiKey;
    } catch (e, s) {
        _log.e("Failed to read API key for $provider", error: e, stackTrace: s);
        // Don't throw here, just return null as key might not exist
        return null;
    }
  }

  /// Set active provider (stored as index string)
  Future<void> setActiveProvider(LlmProvider provider) async {
    try {
      await _secureStorage.write(key: _activeProviderPref, value: provider.index.toString());
      _log.i("Active LLM provider set to: $provider");
    } catch (e, s) {
       _log.e("Failed to set active provider", error: e, stackTrace: s);
       throw ApiKeyException("Failed to write active provider to secure storage", underlyingError: e);
    }
  }

  /// Get active provider (defaults to NVIDIA if not set or invalid)
  Future<LlmProvider> getActiveProvider() async {
     LlmProvider defaultProvider = LlmProvider.nvidia;
     try {
        final indexString = await _secureStorage.read(key: _activeProviderPref);
        if (indexString != null) {
           final index = int.tryParse(indexString);
           if (index != null && index >= 0 && index < LlmProvider.values.length) {
              final provider = LlmProvider.values[index];
               _log.d("Retrieved active provider: $provider");
              return provider;
           } else {
               _log.w("Invalid active provider index found: '$indexString'. Defaulting to $defaultProvider");
           }
        } else {
            _log.d("No active provider preference found. Defaulting to $defaultProvider");
        }
     } catch (e, s) {
        _log.e("Failed to read active provider. Defaulting to $defaultProvider", error: e, stackTrace: s);
     }
     return defaultProvider; // Default
  }

  /// Get a client for the active provider. Throws ApiKeyException if key missing.
  Future<BaseLlmClient> getActiveClient({Duration? timeout}) async {
    final provider = await getActiveProvider();
    final apiKey = await getApiKey(provider);

    if (apiKey == null || apiKey.isEmpty) {
      _log.e("API Key for active provider ($provider) not found or empty.");
      throw ApiKeyException("API Key for active provider ($provider) is not set.");
    }

    _log.i("Creating LLM client for active provider: $provider");

    String modelName;
    // Consider making models configurable later
    switch (provider) {
      case LlmProvider.nvidia: modelName = 'google/gemma-2-27b-it'; break;
      case LlmProvider.groq: modelName = 'gemma2-9b-it'; break;
      case LlmProvider.gemini: modelName = 'gemma2-9b-it'; break; // Use flash for faster classification? Or 1.5-pro?
    }

    try {
       return LlmClientFactory.createClient(
         provider: provider,
         apiKey: apiKey,
         modelName: modelName,
         timeout: timeout,
       );
    } catch (e, s) {
        _log.e("Failed to create LLM Client", error: e, stackTrace: s);
        // Rethrow as a more specific error or handle
        throw LlmException("Failed to instantiate LLM client", underlyingError: e);
    }
  }
}


/// Helper class to process voice commands for Liquid Galaxy
class VoiceCommandProcessor {
  // Requires an initialized client to be passed in
  final BaseLlmClient llm;
  late final IntentClassifierService intentClassifier;
  late final KmlGeneratorService kmlGenerator;
  final Logger _log = logger;

  VoiceCommandProcessor({required this.llm}) {
    intentClassifier = IntentClassifierService(llm: llm);
    kmlGenerator = KmlGeneratorService(llm: llm);
  }

  /// Process a voice command and get action to perform.
  /// Returns a result map or throws exceptions.
  Future<Map<String, dynamic>> processVoiceCommand(String voiceCommand) async {
    _log.i("Processing voice command: '$voiceCommand'");

    // Step 1: Classify the intent
    Map<String, dynamic> intentResult;
    try {
      intentResult = await intentClassifier.classifyIntent(voiceCommand);
       _log.d("Intent classification result: $intentResult");
    } catch (e, s) {
       _log.e("Intent classification failed for command '$voiceCommand'", error: e, stackTrace: s);
       // Return a failure result map or rethrow
       return {
         'success': false,
         'action': 'ERROR_CLASSIFICATION',
         'message': 'Failed to understand command intent.',
         'error': e.toString(),
       };
        // Or rethrow e;
    }

    final intentType = intentResult['intent'] as String?; // Safely cast

    if (intentType == null || intentType == 'UNKNOWN') {
       _log.w("Intent was classified as UNKNOWN or missing.");
      return {
        'success': false,
        'action': 'UNKNOWN',
        'message': 'Could not determine a specific action for the command.',
        'original_query': voiceCommand,
        'details': intentResult, // Include details for debugging
      };
    }

    // Step 2: Handle the intent based on its type
    if (intentType == 'GENERATE_KML') {
      _log.i("Intent is GENERATE_KML. Proceeding to KML generation.");
      final query = intentResult['query'] as String? ?? voiceCommand; // Fallback to original command

      try {
         final kml = await kmlGenerator.generateKml(query);
         _log.i("KML generation successful for query '$query'.");
         return {
           'success': true,
           'action': 'GENERATE_KML',
           'kml': kml,
           'original_intent': intentResult, // Include original classification for context
         };
      } catch (e, s) {
         _log.e("KML generation failed for query '$query'", error: e, stackTrace: s);
         return {
           'success': false,
           'action': 'ERROR_KML_GENERATION',
           'message': 'Failed to generate the requested KML.',
           'error': e.toString(),
           'original_intent': intentResult,
         };
          // Or rethrow e;
      }

    } else {
      // For other direct intents (CLEAR_KML, PLAY_TOUR, etc.)
       _log.i("Intent is a direct command: $intentType");
      return {
        'success': true,
        'action': intentType, // Pass the classified intent directly
        'params': intentResult, // Pass all params received from classification
      };
    }
  }
}


/// Provider model for the active LLM to be used with Provider package
class ActiveLlmProvider extends ChangeNotifier {
  BaseLlmClient? _client;
  LlmProvider _provider = LlmProvider.nvidia; // Default provider
  bool _isLoading = false;
  String? _error;
  final ApiKeyManager _apiKeyManager = ApiKeyManager(); // Instance of the manager
  final Logger _log = logger;

  BaseLlmClient? get client => _client;
  LlmProvider get provider => _provider;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isReady => _client != null && !_isLoading;

  /// Initialize the provider from saved preferences. Call this early.
  Future<void> initialize() async {
    _log.i("Initializing ActiveLlmProvider...");
    _isLoading = true;
    _error = null;
    // Notify immediately that loading has started
    // Use WidgetsBinding.instance.addPostFrameCallback or Future.microtask
    // if calling this during build phase, otherwise direct notifyListeners is fine.
    notifyListeners();

    try {
      _provider = await _apiKeyManager.getActiveProvider();
      _log.d("Retrieved active provider preference: $_provider");
      // Attempt to get the client, which implicitly checks the API key
      _client = await _apiKeyManager.getActiveClient();
      _log.i("LLM Client initialized successfully for $_provider.");
    } on ApiKeyException catch (e) {
       _log.w("Initialization failed: API key missing for provider $_provider", error: e);
      _error = e.message; // Inform user key is missing
      _client = null;
    } catch (e, s) {
       _log.e("Error initializing LLM provider", error: e, stackTrace: s);
      _error = 'Failed to initialize LLM: ${e.toString()}';
      _client = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Switch to a different provider
  Future<void> switchProvider(LlmProvider newProvider) async {
     _log.i("Attempting to switch provider to $newProvider");
    if (newProvider == _provider && _client != null) {
       _log.d("Provider $newProvider is already active and client exists. No switch needed.");
      return; // Avoid unnecessary work
    }

    _isLoading = true;
    _error = null;
    _client = null; // Clear old client immediately
    notifyListeners();

    try {
      // Check if key exists *before* setting active provider pref
      final apiKey = await _apiKeyManager.getApiKey(newProvider);
      if (apiKey == null || apiKey.isEmpty) {
        _log.w("Cannot switch to $newProvider: API Key not found.");
        throw ApiKeyException("API Key for provider $newProvider is not set.");
      }

      _provider = newProvider;
      await _apiKeyManager.setActiveProvider(newProvider); // Save preference
      _client = await _apiKeyManager.getActiveClient(); // Create new client
      _log.i("Successfully switched provider to $newProvider.");

    } on ApiKeyException catch (e) {
       _log.w("Switch failed: API key missing for provider $newProvider", error: e);
       _error = e.message; // Keep error message specific to key missing
    } catch (e, s) {
       _log.e("Error switching provider to $newProvider", error: e, stackTrace: s);
      _error = 'Failed to switch provider: ${e.toString()}';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Update API key for the current provider
  Future<void> updateApiKey(String apiKey) async {
     _log.i("Attempting to update API Key for current provider: $_provider");
    if (apiKey.isEmpty) {
        _log.w("Attempted to update with an empty API key.");
        _error = "API key cannot be empty.";
        notifyListeners();
        return;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _apiKeyManager.saveApiKey(_provider, apiKey);
      // Re-create the client with the new key
      _client = await _apiKeyManager.getActiveClient();
      _log.i("API Key updated and client refreshed for $_provider.");
    } catch (e, s) {
       _log.e("Error updating API key for $_provider", error: e, stackTrace: s);
       _error = 'Failed to update API key: ${e.toString()}';
       _client = null; // Client might be invalid now
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}