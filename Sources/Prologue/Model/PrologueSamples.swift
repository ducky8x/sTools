/// Fixtures the Prologue ships with.
public enum PrologueSamples {
    /// A Ninjabrain Bot `/api/v1/stronghold` body: two eye throws triangulated to one likely stronghold. The NBB
    /// Overlay trial shows it only while Ninjabrain Bot isn't connected (spec D5), labeled as a sample; nothing
    /// else in sTools ever uses it.
    public static let ninjabrainBotStronghold = """
    {
      "resultType": "TRIANGULATION",
      "predictions": [
        {"chunkX": -41, "chunkZ": 108, "certainty": 0.942, "overworldDistance": 1579.6},
        {"chunkX": -40, "chunkZ": 112, "certainty": 0.041, "overworldDistance": 1625.0},
        {"chunkX": -43, "chunkZ": 105, "certainty": 0.012, "overworldDistance": 1556.3}
      ],
      "eyeThrows": [
        {"xInOverworld": 214.37, "zInOverworld": -96.52, "angle": 25.20, "angleWithoutCorrection": 25.18,
         "correction": 0.02, "correctionIncrements": 1, "error": 0.0031, "type": "NORMAL"},
        {"xInOverworld": 198.02, "zInOverworld": 402.77, "angle": 32.39, "angleWithoutCorrection": 32.39,
         "correction": 0.0, "correctionIncrements": 0, "error": 0.0012, "type": "NORMAL"}
      ],
      "playerPosition": {"xInOverworld": 198.02, "zInOverworld": 402.77, "horizontalAngle": 32.39,
                         "isInOverworld": true, "isInNether": false}
    }
    """
}
