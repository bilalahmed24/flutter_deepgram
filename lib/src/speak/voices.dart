/// Catalogs of every Deepgram text-to-speech voice ID.
///
/// Three families of voices are available:
///
/// * **Aura** — the 12 original English voices, served by `/v1/speak`.
/// * **Aura-2** — 90 additional voices across English, Spanish, German,
///   Dutch, French, Italian, and Japanese, also served by `/v1/speak`.
/// * **Flux TTS** — 36 turn-based voices (`flux-{voice}-{lang}`), served
///   by `/v2/speak` and built for voice-agent pipelines.
///
/// ```dart
/// final audio = await deepgram.tts.speak(
///   'Hello, world!',
///   options: const SpeakOptions(model: DeepgramVoices.aura2ThaliaEn),
/// );
///
/// final flux = deepgram.createFluxTtsClient(
///   options: const FluxTtsOptions(model: DeepgramVoices.fluxAlexisEn),
/// );
/// ```
library;

/// Static voice-ID catalogs for Deepgram text-to-speech.
///
/// Every member is a compile-time constant. Use the `is*Voice` helpers to
/// validate user-supplied voice IDs before sending a request.
class DeepgramVoices {
  /// This class holds only static members and cannot be instantiated.
  DeepgramVoices._();

  // ---------------------------------------------------------------------
  // Aura (v1) — the 12 original voices, all English.
  // ---------------------------------------------------------------------

  /// Aura voice "Angus" — male, English.
  static const String auraAngusEn = 'aura-angus-en';

  /// Aura voice "Arcas" — male, English.
  static const String auraArcasEn = 'aura-arcas-en';

  /// Aura voice "Asteria" — female, English. The server-side default.
  static const String auraAsteriaEn = 'aura-asteria-en';

  /// Aura voice "Athena" — female, English.
  static const String auraAthenaEn = 'aura-athena-en';

  /// Aura voice "Helios" — male, English.
  static const String auraHeliosEn = 'aura-helios-en';

  /// Aura voice "Hera" — female, English.
  static const String auraHeraEn = 'aura-hera-en';

  /// Aura voice "Luna" — female, English.
  static const String auraLunaEn = 'aura-luna-en';

  /// Aura voice "Orion" — male, English.
  static const String auraOrionEn = 'aura-orion-en';

  /// Aura voice "Orpheus" — male, English.
  static const String auraOrpheusEn = 'aura-orpheus-en';

  /// Aura voice "Perseus" — male, English.
  static const String auraPerseusEn = 'aura-perseus-en';

  /// Aura voice "Stella" — female, English.
  static const String auraStellaEn = 'aura-stella-en';

  /// Aura voice "Zeus" — male, English.
  static const String auraZeusEn = 'aura-zeus-en';

  // ---------------------------------------------------------------------
  // Aura-2 — English voices.
  // ---------------------------------------------------------------------

  /// Aura-2 voice "Amalthea" — English.
  static const String aura2AmaltheaEn = 'aura-2-amalthea-en';

  /// Aura-2 voice "Andromeda" — English.
  static const String aura2AndromedaEn = 'aura-2-andromeda-en';

  /// Aura-2 voice "Apollo" — English.
  static const String aura2ApolloEn = 'aura-2-apollo-en';

  /// Aura-2 voice "Arcas" — English.
  static const String aura2ArcasEn = 'aura-2-arcas-en';

  /// Aura-2 voice "Aries" — English.
  static const String aura2AriesEn = 'aura-2-aries-en';

  /// Aura-2 voice "Asteria" — English.
  static const String aura2AsteriaEn = 'aura-2-asteria-en';

  /// Aura-2 voice "Athena" — English.
  static const String aura2AthenaEn = 'aura-2-athena-en';

  /// Aura-2 voice "Atlas" — English.
  static const String aura2AtlasEn = 'aura-2-atlas-en';

  /// Aura-2 voice "Aurora" — English.
  static const String aura2AuroraEn = 'aura-2-aurora-en';

  /// Aura-2 voice "Callista" — English.
  static const String aura2CallistaEn = 'aura-2-callista-en';

  /// Aura-2 voice "Cora" — English.
  static const String aura2CoraEn = 'aura-2-cora-en';

  /// Aura-2 voice "Cordelia" — English.
  static const String aura2CordeliaEn = 'aura-2-cordelia-en';

  /// Aura-2 voice "Delia" — English.
  static const String aura2DeliaEn = 'aura-2-delia-en';

  /// Aura-2 voice "Draco" — English.
  static const String aura2DracoEn = 'aura-2-draco-en';

  /// Aura-2 voice "Electra" — English.
  static const String aura2ElectraEn = 'aura-2-electra-en';

  /// Aura-2 voice "Harmonia" — English.
  static const String aura2HarmoniaEn = 'aura-2-harmonia-en';

  /// Aura-2 voice "Helena" — English.
  static const String aura2HelenaEn = 'aura-2-helena-en';

  /// Aura-2 voice "Hera" — English.
  static const String aura2HeraEn = 'aura-2-hera-en';

  /// Aura-2 voice "Hermes" — English.
  static const String aura2HermesEn = 'aura-2-hermes-en';

  /// Aura-2 voice "Hyperion" — English.
  static const String aura2HyperionEn = 'aura-2-hyperion-en';

  /// Aura-2 voice "Iris" — English.
  static const String aura2IrisEn = 'aura-2-iris-en';

  /// Aura-2 voice "Janus" — English.
  static const String aura2JanusEn = 'aura-2-janus-en';

  /// Aura-2 voice "Juno" — English.
  static const String aura2JunoEn = 'aura-2-juno-en';

  /// Aura-2 voice "Jupiter" — English.
  static const String aura2JupiterEn = 'aura-2-jupiter-en';

  /// Aura-2 voice "Luna" — English.
  static const String aura2LunaEn = 'aura-2-luna-en';

  /// Aura-2 voice "Mars" — English.
  static const String aura2MarsEn = 'aura-2-mars-en';

  /// Aura-2 voice "Minerva" — English.
  static const String aura2MinervaEn = 'aura-2-minerva-en';

  /// Aura-2 voice "Neptune" — English.
  static const String aura2NeptuneEn = 'aura-2-neptune-en';

  /// Aura-2 voice "Odysseus" — English.
  static const String aura2OdysseusEn = 'aura-2-odysseus-en';

  /// Aura-2 voice "Ophelia" — English.
  static const String aura2OpheliaEn = 'aura-2-ophelia-en';

  /// Aura-2 voice "Orion" — English.
  static const String aura2OrionEn = 'aura-2-orion-en';

  /// Aura-2 voice "Orpheus" — English.
  static const String aura2OrpheusEn = 'aura-2-orpheus-en';

  /// Aura-2 voice "Pandora" — English.
  static const String aura2PandoraEn = 'aura-2-pandora-en';

  /// Aura-2 voice "Phoebe" — English.
  static const String aura2PhoebeEn = 'aura-2-phoebe-en';

  /// Aura-2 voice "Pluto" — English.
  static const String aura2PlutoEn = 'aura-2-pluto-en';

  /// Aura-2 voice "Saturn" — English.
  static const String aura2SaturnEn = 'aura-2-saturn-en';

  /// Aura-2 voice "Selene" — English.
  static const String aura2SeleneEn = 'aura-2-selene-en';

  /// Aura-2 voice "Thalia" — English.
  static const String aura2ThaliaEn = 'aura-2-thalia-en';

  /// Aura-2 voice "Theia" — English.
  static const String aura2TheiaEn = 'aura-2-theia-en';

  /// Aura-2 voice "Vesta" — English.
  static const String aura2VestaEn = 'aura-2-vesta-en';

  /// Aura-2 voice "Zeus" — English.
  static const String aura2ZeusEn = 'aura-2-zeus-en';

  // ---------------------------------------------------------------------
  // Aura-2 — Spanish voices.
  // ---------------------------------------------------------------------

  /// Aura-2 voice "Agustina" — Spanish.
  static const String aura2AgustinaEs = 'aura-2-agustina-es';

  /// Aura-2 voice "Alvaro" — Spanish.
  static const String aura2AlvaroEs = 'aura-2-alvaro-es';

  /// Aura-2 voice "Antonia" — Spanish.
  static const String aura2AntoniaEs = 'aura-2-antonia-es';

  /// Aura-2 voice "Aquila" — Spanish.
  static const String aura2AquilaEs = 'aura-2-aquila-es';

  /// Aura-2 voice "Carina" — Spanish.
  static const String aura2CarinaEs = 'aura-2-carina-es';

  /// Aura-2 voice "Celeste" — Spanish.
  static const String aura2CelesteEs = 'aura-2-celeste-es';

  /// Aura-2 voice "Diana" — Spanish.
  static const String aura2DianaEs = 'aura-2-diana-es';

  /// Aura-2 voice "Estrella" — Spanish.
  static const String aura2EstrellaEs = 'aura-2-estrella-es';

  /// Aura-2 voice "Gloria" — Spanish.
  static const String aura2GloriaEs = 'aura-2-gloria-es';

  /// Aura-2 voice "Javier" — Spanish.
  static const String aura2JavierEs = 'aura-2-javier-es';

  /// Aura-2 voice "Luciano" — Spanish.
  static const String aura2LucianoEs = 'aura-2-luciano-es';

  /// Aura-2 voice "Nestor" — Spanish.
  static const String aura2NestorEs = 'aura-2-nestor-es';

  /// Aura-2 voice "Olivia" — Spanish.
  static const String aura2OliviaEs = 'aura-2-olivia-es';

  /// Aura-2 voice "Selena" — Spanish.
  static const String aura2SelenaEs = 'aura-2-selena-es';

  /// Aura-2 voice "Silvia" — Spanish.
  static const String aura2SilviaEs = 'aura-2-silvia-es';

  /// Aura-2 voice "Sirio" — Spanish.
  static const String aura2SirioEs = 'aura-2-sirio-es';

  /// Aura-2 voice "Valerio" — Spanish.
  static const String aura2ValerioEs = 'aura-2-valerio-es';

  // ---------------------------------------------------------------------
  // Aura-2 — German voices.
  // ---------------------------------------------------------------------

  /// Aura-2 voice "Aurelia" — German.
  static const String aura2AureliaDe = 'aura-2-aurelia-de';

  /// Aura-2 voice "Elara" — German.
  static const String aura2ElaraDe = 'aura-2-elara-de';

  /// Aura-2 voice "Fabian" — German.
  static const String aura2FabianDe = 'aura-2-fabian-de';

  /// Aura-2 voice "Julius" — German.
  static const String aura2JuliusDe = 'aura-2-julius-de';

  /// Aura-2 voice "Kara" — German.
  static const String aura2KaraDe = 'aura-2-kara-de';

  /// Aura-2 voice "Lara" — German.
  static const String aura2LaraDe = 'aura-2-lara-de';

  /// Aura-2 voice "Viktoria" — German.
  static const String aura2ViktoriaDe = 'aura-2-viktoria-de';

  // ---------------------------------------------------------------------
  // Aura-2 — Dutch voices.
  // ---------------------------------------------------------------------

  /// Aura-2 voice "Beatrix" — Dutch.
  static const String aura2BeatrixNl = 'aura-2-beatrix-nl';

  /// Aura-2 voice "Cornelia" — Dutch.
  static const String aura2CorneliaNl = 'aura-2-cornelia-nl';

  /// Aura-2 voice "Daphne" — Dutch.
  static const String aura2DaphneNl = 'aura-2-daphne-nl';

  /// Aura-2 voice "Hestia" — Dutch.
  static const String aura2HestiaNl = 'aura-2-hestia-nl';

  /// Aura-2 voice "Lars" — Dutch.
  static const String aura2LarsNl = 'aura-2-lars-nl';

  /// Aura-2 voice "Leda" — Dutch.
  static const String aura2LedaNl = 'aura-2-leda-nl';

  /// Aura-2 voice "Rhea" — Dutch.
  static const String aura2RheaNl = 'aura-2-rhea-nl';

  /// Aura-2 voice "Roman" — Dutch.
  static const String aura2RomanNl = 'aura-2-roman-nl';

  /// Aura-2 voice "Sander" — Dutch.
  static const String aura2SanderNl = 'aura-2-sander-nl';

  // ---------------------------------------------------------------------
  // Aura-2 — French voices.
  // ---------------------------------------------------------------------

  /// Aura-2 voice "Agathe" — French.
  static const String aura2AgatheFr = 'aura-2-agathe-fr';

  /// Aura-2 voice "Hector" — French.
  static const String aura2HectorFr = 'aura-2-hector-fr';

  // ---------------------------------------------------------------------
  // Aura-2 — Italian voices.
  // ---------------------------------------------------------------------

  /// Aura-2 voice "Cesare" — Italian.
  static const String aura2CesareIt = 'aura-2-cesare-it';

  /// Aura-2 voice "Cinzia" — Italian.
  static const String aura2CinziaIt = 'aura-2-cinzia-it';

  /// Aura-2 voice "Demetra" — Italian.
  static const String aura2DemetraIt = 'aura-2-demetra-it';

  /// Aura-2 voice "Dionisio" — Italian.
  static const String aura2DionisioIt = 'aura-2-dionisio-it';

  /// Aura-2 voice "Elio" — Italian.
  static const String aura2ElioIt = 'aura-2-elio-it';

  /// Aura-2 voice "Flavio" — Italian.
  static const String aura2FlavioIt = 'aura-2-flavio-it';

  /// Aura-2 voice "Livia" — Italian.
  static const String aura2LiviaIt = 'aura-2-livia-it';

  /// Aura-2 voice "Maia" — Italian.
  static const String aura2MaiaIt = 'aura-2-maia-it';

  /// Aura-2 voice "Melia" — Italian.
  static const String aura2MeliaIt = 'aura-2-melia-it';

  // ---------------------------------------------------------------------
  // Aura-2 — Japanese voices.
  // ---------------------------------------------------------------------

  /// Aura-2 voice "Ama" — Japanese.
  static const String aura2AmaJa = 'aura-2-ama-ja';

  /// Aura-2 voice "Ebisu" — Japanese.
  static const String aura2EbisuJa = 'aura-2-ebisu-ja';

  /// Aura-2 voice "Fujin" — Japanese.
  static const String aura2FujinJa = 'aura-2-fujin-ja';

  /// Aura-2 voice "Izanami" — Japanese.
  static const String aura2IzanamiJa = 'aura-2-izanami-ja';

  /// Aura-2 voice "Uzume" — Japanese.
  static const String aura2UzumeJa = 'aura-2-uzume-ja';

  // ---------------------------------------------------------------------
  // Flux TTS (v2) — turn-based voices, all English.
  // ---------------------------------------------------------------------

  /// Flux TTS voice "Alexis" — English.
  static const String fluxAlexisEn = 'flux-alexis-en';

  /// Flux TTS voice "Bree" — English.
  static const String fluxBreeEn = 'flux-bree-en';

  /// Flux TTS voice "Brittany" — English.
  static const String fluxBrittanyEn = 'flux-brittany-en';

  /// Flux TTS voice "Brooke" — English.
  static const String fluxBrookeEn = 'flux-brooke-en';

  /// Flux TTS voice "Bruce" — English.
  static const String fluxBruceEn = 'flux-bruce-en';

  /// Flux TTS voice "Cliff" — English.
  static const String fluxCliffEn = 'flux-cliff-en';

  /// Flux TTS voice "Cole" — English.
  static const String fluxColeEn = 'flux-cole-en';

  /// Flux TTS voice "Colin" — English.
  static const String fluxColinEn = 'flux-colin-en';

  /// Flux TTS voice "Conor" — English.
  static const String fluxConorEn = 'flux-conor-en';

  /// Flux TTS voice "Donovan" — English.
  static const String fluxDonovanEn = 'flux-donovan-en';

  /// Flux TTS voice "Drew" — English.
  static const String fluxDrewEn = 'flux-drew-en';

  /// Flux TTS voice "Elise" — English.
  static const String fluxEliseEn = 'flux-elise-en';

  /// Flux TTS voice "Gemma" — English.
  static const String fluxGemmaEn = 'flux-gemma-en';

  /// Flux TTS voice "Haley" — English.
  static const String fluxHaleyEn = 'flux-haley-en';

  /// Flux TTS voice "Hannah" — English.
  static const String fluxHannahEn = 'flux-hannah-en';

  /// Flux TTS voice "Heather" — English.
  static const String fluxHeatherEn = 'flux-heather-en';

  /// Flux TTS voice "Jack" — English.
  static const String fluxJackEn = 'flux-jack-en';

  /// Flux TTS voice "Kai" — English.
  static const String fluxKaiEn = 'flux-kai-en';

  /// Flux TTS voice "Kelsey" — English.
  static const String fluxKelseyEn = 'flux-kelsey-en';

  /// Flux TTS voice "Kit" — English.
  static const String fluxKitEn = 'flux-kit-en';

  /// Flux TTS voice "Maeve" — English.
  static const String fluxMaeveEn = 'flux-maeve-en';

  /// Flux TTS voice "Marcelo" — English.
  static const String fluxMarceloEn = 'flux-marcelo-en';

  /// Flux TTS voice "Marcus" — English.
  static const String fluxMarcusEn = 'flux-marcus-en';

  /// Flux TTS voice "Meena" — English.
  static const String fluxMeenaEn = 'flux-meena-en';

  /// Flux TTS voice "Meghan" — English.
  static const String fluxMeghanEn = 'flux-meghan-en';

  /// Flux TTS voice "Miles" — English.
  static const String fluxMilesEn = 'flux-miles-en';

  /// Flux TTS voice "Naveen" — English.
  static const String fluxNaveenEn = 'flux-naveen-en';

  /// Flux TTS voice "Paige" — English.
  static const String fluxPaigeEn = 'flux-paige-en';

  /// Flux TTS voice "Priya" — English.
  static const String fluxPriyaEn = 'flux-priya-en';

  /// Flux TTS voice "Rufus" — English.
  static const String fluxRufusEn = 'flux-rufus-en';

  /// Flux TTS voice "Sean" — English.
  static const String fluxSeanEn = 'flux-sean-en';

  /// Flux TTS voice "Sharon" — English.
  static const String fluxSharonEn = 'flux-sharon-en';

  /// Flux TTS voice "Sienna" — English.
  static const String fluxSiennaEn = 'flux-sienna-en';

  /// Flux TTS voice "Tanner" — English.
  static const String fluxTannerEn = 'flux-tanner-en';

  /// Flux TTS voice "Wade" — English.
  static const String fluxWadeEn = 'flux-wade-en';

  /// Flux TTS voice "Wes" — English.
  static const String fluxWesEn = 'flux-wes-en';

  // ---------------------------------------------------------------------
  // Catalogs and lookups.
  // ---------------------------------------------------------------------

  /// The server-side default voice for `/v1/speak`.
  static const String defaultVoice = auraAsteriaEn;

  /// All 12 original Aura (v1) voices.
  static const List<String> aura = <String>[
    auraAngusEn,
    auraArcasEn,
    auraAsteriaEn,
    auraAthenaEn,
    auraHeliosEn,
    auraHeraEn,
    auraLunaEn,
    auraOrionEn,
    auraOrpheusEn,
    auraPerseusEn,
    auraStellaEn,
    auraZeusEn,
  ];

  /// All 90 Aura-2 voices (English, Spanish, German, Dutch, French,
  /// Italian, and Japanese).
  static const List<String> aura2 = <String>[
    aura2AmaltheaEn,
    aura2AndromedaEn,
    aura2ApolloEn,
    aura2ArcasEn,
    aura2AriesEn,
    aura2AsteriaEn,
    aura2AthenaEn,
    aura2AtlasEn,
    aura2AuroraEn,
    aura2CallistaEn,
    aura2CoraEn,
    aura2CordeliaEn,
    aura2DeliaEn,
    aura2DracoEn,
    aura2ElectraEn,
    aura2HarmoniaEn,
    aura2HelenaEn,
    aura2HeraEn,
    aura2HermesEn,
    aura2HyperionEn,
    aura2IrisEn,
    aura2JanusEn,
    aura2JunoEn,
    aura2JupiterEn,
    aura2LunaEn,
    aura2MarsEn,
    aura2MinervaEn,
    aura2NeptuneEn,
    aura2OdysseusEn,
    aura2OpheliaEn,
    aura2OrionEn,
    aura2OrpheusEn,
    aura2PandoraEn,
    aura2PhoebeEn,
    aura2PlutoEn,
    aura2SaturnEn,
    aura2SeleneEn,
    aura2ThaliaEn,
    aura2TheiaEn,
    aura2VestaEn,
    aura2ZeusEn,
    aura2AgustinaEs,
    aura2AlvaroEs,
    aura2AntoniaEs,
    aura2AquilaEs,
    aura2CarinaEs,
    aura2CelesteEs,
    aura2DianaEs,
    aura2EstrellaEs,
    aura2GloriaEs,
    aura2JavierEs,
    aura2LucianoEs,
    aura2NestorEs,
    aura2OliviaEs,
    aura2SelenaEs,
    aura2SilviaEs,
    aura2SirioEs,
    aura2ValerioEs,
    aura2AureliaDe,
    aura2ElaraDe,
    aura2FabianDe,
    aura2JuliusDe,
    aura2KaraDe,
    aura2LaraDe,
    aura2ViktoriaDe,
    aura2BeatrixNl,
    aura2CorneliaNl,
    aura2DaphneNl,
    aura2HestiaNl,
    aura2LarsNl,
    aura2LedaNl,
    aura2RheaNl,
    aura2RomanNl,
    aura2SanderNl,
    aura2AgatheFr,
    aura2HectorFr,
    aura2CesareIt,
    aura2CinziaIt,
    aura2DemetraIt,
    aura2DionisioIt,
    aura2ElioIt,
    aura2FlavioIt,
    aura2LiviaIt,
    aura2MaiaIt,
    aura2MeliaIt,
    aura2AmaJa,
    aura2EbisuJa,
    aura2FujinJa,
    aura2IzanamiJa,
    aura2UzumeJa,
  ];

  /// All 36 Flux TTS voices (`/v2/speak`), all English.
  static const List<String> flux = <String>[
    fluxAlexisEn,
    fluxBreeEn,
    fluxBrittanyEn,
    fluxBrookeEn,
    fluxBruceEn,
    fluxCliffEn,
    fluxColeEn,
    fluxColinEn,
    fluxConorEn,
    fluxDonovanEn,
    fluxDrewEn,
    fluxEliseEn,
    fluxGemmaEn,
    fluxHaleyEn,
    fluxHannahEn,
    fluxHeatherEn,
    fluxJackEn,
    fluxKaiEn,
    fluxKelseyEn,
    fluxKitEn,
    fluxMaeveEn,
    fluxMarceloEn,
    fluxMarcusEn,
    fluxMeenaEn,
    fluxMeghanEn,
    fluxMilesEn,
    fluxNaveenEn,
    fluxPaigeEn,
    fluxPriyaEn,
    fluxRufusEn,
    fluxSeanEn,
    fluxSharonEn,
    fluxSiennaEn,
    fluxTannerEn,
    fluxWadeEn,
    fluxWesEn,
  ];

  /// Every voice supported by `/v1/speak` (the 12 Aura voices plus all 90
  /// Aura-2 voices) — 102 in total.
  static const List<String> allV1 = <String>[...aura, ...aura2];

  /// Every Flux TTS voice supported by `/v2/speak`.
  static const List<String> allFlux = <String>[...flux];

  /// Every voice known to this SDK (Aura, Aura-2, and Flux TTS).
  static const List<String> all = <String>[...allV1, ...allFlux];

  /// Returns `true` when [voiceId] is one of the 12 original Aura voices.
  static bool isAuraVoice(String voiceId) => aura.contains(voiceId);

  /// Returns `true` when [voiceId] is an Aura-2 voice.
  static bool isAura2Voice(String voiceId) => aura2.contains(voiceId);

  /// Returns `true` when [voiceId] is a Flux TTS voice.
  static bool isFluxVoice(String voiceId) => flux.contains(voiceId);

  /// Returns `true` when [voiceId] works with `/v1/speak` (Aura or
  /// Aura-2).
  static bool isV1Voice(String voiceId) => allV1.contains(voiceId);

  /// Returns `true` when [voiceId] is any voice known to this SDK.
  static bool isKnownVoice(String voiceId) => all.contains(voiceId);

  /// Returns the language tag of [voiceId] — one of `en`, `es`, `de`,
  /// `nl`, `fr`, `it`, `ja` — or `null` when the voice is unknown.
  static String? languageOf(String voiceId) {
    if (!isKnownVoice(voiceId)) return null;
    final parts = voiceId.split('-');
    if (parts.isEmpty) return null;
    final language = parts.last;
    return language.isEmpty ? null : language;
  }
}
