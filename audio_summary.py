from transformers import pipeline


# --- Configuration ---
AUDIO_PATH = "audios/tokenization_demo.wav"
ASR_MODEL = "openai/whisper-small"
SUMMARIZER_MODEL = "facebook/bart-large-xsum"
MAX_SUMMARY_LENGTH = 60
MIN_SUMMARY_LENGTH = 20


# --- Load pipelines ---
print("Loading ASR model...")
asr = pipeline("automatic-speech-recognition", model=ASR_MODEL, device="cpu", generate_kwargs={"language": "es"})


print("Loading summarization model...")
summarizer = pipeline("summarization", model=SUMMARIZER_MODEL, device="cpu")

# --- Run ASR ---
print(f"Running ASR on: {AUDIO_PATH}")
asr_out = asr(AUDIO_PATH)
transcript = asr_out.get('text', '').strip()

print("\n--- Transcript ---\n")
print(transcript)


if not transcript:
    print("\nWarning: Empty transcript. Check audio file and model.")
else:
    # --- Run summarization ---
    print("\nRunning summarization...")
    summary = summarizer(
        transcript,
        max_length=MAX_SUMMARY_LENGTH,
        min_length=MIN_SUMMARY_LENGTH,
        do_sample=False
    )

    summary_text = summary[0].get('summary_text', '')

    print("\n--- Summary ---\n")
    print(summary_text)
