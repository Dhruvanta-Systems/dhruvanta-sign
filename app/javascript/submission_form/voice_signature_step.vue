<template>
  <div class="text-center">
    <p class="mb-4 text-sm">
      {{ t('please_say') }}: "I, {{ submitterName }}, agree to the terms of this document."
    </p>
    <div
      v-if="!recording && !audioUrl"
      class="space-y-2"
    >
      <button
        class="btn btn-primary"
        @click="startRecording"
      >
        {{ t('start_recording') }}
      </button>
    </div>
    <div
      v-if="recording"
      class="space-y-2"
    >
      <div class="text-error animate-pulse text-lg">
        ● Recording...
      </div>
      <button
        class="btn btn-error"
        @click="stopRecording"
      >
        {{ t('stop') }}
      </button>
    </div>
    <div
      v-if="audioUrl && !recording"
      class="space-y-2"
    >
      <audio
        :src="audioUrl"
        controls
        class="mx-auto"
      />
      <div class="flex justify-center gap-2">
        <button
          class="btn btn-outline btn-sm"
          @click="retake"
        >
          {{ t('retake') }}
        </button>
        <button
          class="btn btn-primary btn-sm"
          @click="$emit('submit', audioBlob)"
        >
          {{ t('use_this_recording') }}
        </button>
      </div>
    </div>
  </div>
</template>
<script>
export default {
  name: 'VoiceSignatureStep',
  props: {
    submitterName: { type: String, default: '' },
    t: { type: Function, default: (key) => key }
  },
  emits: ['submit'],
  data () { return { recording: false, audioUrl: null, audioBlob: null, mediaRecorder: null, chunks: [] } },
  methods: {
    async startRecording () {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      this.mediaRecorder = new MediaRecorder(stream, { mimeType: 'audio/webm' })
      this.chunks = []
      this.mediaRecorder.ondataavailable = (e) => this.chunks.push(e.data)
      this.mediaRecorder.onstop = () => {
        this.audioBlob = new Blob(this.chunks, { type: 'audio/webm' })
        this.audioUrl = URL.createObjectURL(this.audioBlob)
        stream.getTracks().forEach(t => t.stop())
      }
      this.mediaRecorder.start()
      this.recording = true
      setTimeout(() => { if (this.recording) this.stopRecording() }, 30000)
    },
    stopRecording () { if (this.mediaRecorder?.state === 'recording') this.mediaRecorder.stop(); this.recording = false },
    retake () { this.audioUrl = null; this.audioBlob = null }
  }
}
</script>
