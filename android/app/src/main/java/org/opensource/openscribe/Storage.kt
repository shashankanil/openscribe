package org.opensource.openscribe

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import org.json.JSONObject
import org.opensource.openscribe.link.Base64Url
import org.opensource.openscribe.link.CloudConfig
import org.opensource.openscribe.link.LinkProtocol
import org.opensource.openscribe.link.PairingLink
import org.opensource.openscribe.speech.SpeechConfig
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** User preferences. Nothing secret lives here. */
class AppPrefs(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("settings", Context.MODE_PRIVATE)

    var whisperBoost: Boolean
        get() = prefs.getBoolean("whisper_boost", true)
        set(value) = prefs.edit().putBoolean("whisper_boost", value).apply()

    var haptics: Boolean
        get() = prefs.getBoolean("haptics", true)
        set(value) = prefs.edit().putBoolean("haptics", value).apply()

    var autoSendOnOpen: Boolean
        get() = prefs.getBoolean("auto_send_on_open", false)
        set(value) = prefs.edit().putBoolean("auto_send_on_open", value).apply()

    var notificationRationaleDismissed: Boolean
        get() = prefs.getBoolean("notification_rationale_dismissed", false)
        set(value) = prefs.edit().putBoolean("notification_rationale_dismissed", value).apply()

    /** The hardware button that talks (see TalkKeyService), or null for none. */
    var talkKey: TalkKey?
        get() = prefs.getInt("talk_key_code", -1).takeIf { it >= 0 }?.let { TalkKey(it, prefs.getInt("talk_key_scan", 0)) }
        set(value) = prefs.edit().apply {
            if (value == null) remove("talk_key_code").remove("talk_key_scan")
            else putInt("talk_key_code", value.keyCode).putInt("talk_key_scan", value.scanCode)
        }.apply()

    /** Random and stable for this install; Macs use it to replace an old pairing when this phone pairs again. */
    val installId: String
        get() = prefs.getString("install_id", null) ?: java.util.UUID.randomUUID().toString().also {
            prefs.edit().putString("install_id", it).apply()
        }

    /** Send what's copied on the phone to the Mac automatically (needs the accessibility service). */
    var autoSendPhoneCopies: Boolean
        get() = prefs.getBoolean("auto_send_phone_copies", true)
        set(value) = prefs.edit().putBoolean("auto_send_phone_copies", value).apply()

    /** The talk button card on the home screen was dismissed. */
    var talkButtonHintDismissed: Boolean
        get() = prefs.getBoolean("talk_button_hint_dismissed", false)
        set(value) = prefs.edit().putBoolean("talk_button_hint_dismissed", value).apply()

    /** The battery-optimization card on the home screen was dismissed. */
    var batteryPromptDismissed: Boolean
        get() = prefs.getBoolean("battery_prompt_dismissed", false)
        set(value) = prefs.edit().putBoolean("battery_prompt_dismissed", value).apply()

    /** The Send clipboard tile is in Quick Settings, or the user said no; stop offering it. */
    var tilePromptDone: Boolean
        get() = prefs.getBoolean("tile_prompt_done", false)
        set(value) = prefs.edit().putBoolean("tile_prompt_done", value).apply()

    /** Successful dictations so far; the gesture hints get quieter once someone has used it a few times. */
    var talkCount: Int
        get() = prefs.getInt("talk_count", 0)
        set(value) = prefs.edit().putInt("talk_count", value).apply()
}

/** Somewhere to keep strings: SharedPreferences in the app, a map in tests. */
interface StringStore {
    fun get(key: String): String?
    /** Null removes the key. */
    fun set(key: String, value: String?)
}

/** Encrypts strings at rest: the Android Keystore in the app. */
interface SecretBox {
    fun seal(plain: String): String
    fun open(sealed: String): String
}

/**
 * What each paired Mac handed this phone, kept apart by mac id and encrypted with [box]: OpenScribe Cloud access
 * (`{"t":"cloud"}`) and the transcription settings (`{"t":"speech"}`, which include an API key). A Mac only ever
 * reads and replaces its own entry, and [forget] removes everything one Mac left.
 */
class MacSecrets(private val store: StringStore, private val box: SecretBox) {
    fun cloud(): Map<String, CloudConfig> = load(CLOUD, CloudConfig::fromJson)

    fun saveCloud(configs: Map<String, CloudConfig>) = save(CLOUD, configs) { it.toJson() }

    fun speech(): Map<String, SpeechConfig> = load(SPEECH, SpeechConfig::fromJson)

    fun saveSpeech(configs: Map<String, SpeechConfig>) = save(SPEECH, configs) { it.toJson() }

    /** Removes [macId]'s cloud access and speech settings, leaving every other Mac's alone. */
    fun forget(macId: String) {
        cloud().let { if (macId in it) saveCloud(it - macId) }
        speech().let { if (macId in it) saveSpeech(it - macId) }
    }

    private fun <T> load(key: String, parse: (JSONObject) -> T?): Map<String, T> = try {
        store.get(key)?.let { stored ->
            val json = JSONObject(box.open(stored))
            json.keys().asSequence().mapNotNull { macId -> json.optJSONObject(macId)?.let(parse)?.let { macId to it } }.toMap()
        } ?: emptyMap()
    } catch (e: Exception) {
        // Never log the exception text: it could quote stored values.
        Log.w("OpenScribe", "Stored $key settings could not be read (${e.javaClass.simpleName})")
        emptyMap()
    }

    private fun <T> save(key: String, configs: Map<String, T>, json: (T) -> JSONObject) {
        if (configs.isEmpty()) store.set(key, null)
        else {
            val all = JSONObject()
            configs.forEach { (macId, config) -> all.put(macId, json(config)) }
            store.set(key, box.seal(all.toString()))
        }
    }

    companion object {
        /** Encrypted JSON object: mac id to `{"url","token"}`. */
        const val CLOUD = "cloud"
        /** Encrypted JSON object: mac id to `{"provider","url","model","key","streaming","terms"}`. */
        const val SPEECH = "speech"
    }
}

/**
 * Every Mac this phone is paired with (each link carries its shared secret), encrypted with an AES-256-GCM key
 * that never leaves the Android Keystore, plus which one is active, and what each Mac granted ([MacSecrets],
 * encrypted the same way). Excluded from backups, so a restored phone has to pair again.
 */
object PairingStore {
    private const val ALIAS = "openscribe_pairing_v1"
    private const val PREFS = "pairing"
    /** Before multiple Macs: a single encrypted link. Read once and migrated. */
    private const val LEGACY_KEY = "link"
    private const val KEY = "links"
    private const val ACTIVE = "active_mac"
    /** The key that encrypts cached clipboard images, itself encrypted with the Keystore key. */
    private const val CLIP_KEY = "clip_key"

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private fun decrypt(stored: String): String {
        val iv = Base64Url.decode(stored.substringBefore('.'))!!
        val ciphertext = Base64Url.decode(stored.substringAfter('.'))!!
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ciphertext = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64Url.encode(cipher.iv) + "." + Base64Url.encode(ciphertext)
    }

    private object KeystoreBox : SecretBox {
        override fun seal(plain: String) = encrypt(plain)
        override fun open(sealed: String) = decrypt(sealed)
    }

    private class PrefsStore(context: Context) : StringStore {
        private val prefs = prefs(context)
        override fun get(key: String): String? = prefs.getString(key, null)
        override fun set(key: String, value: String?) {
            prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.commit()
        }
    }

    /** Cloud access and speech settings per Mac. */
    fun secrets(context: Context) = MacSecrets(PrefsStore(context), KeystoreBox)

    fun loadAll(context: Context): List<PairingLink> {
        val prefs = prefs(context)
        return try {
            prefs.getString(KEY, null)?.let { decrypt(it).lines().mapNotNull(PairingLink::parse) }
                ?: prefs.getString(LEGACY_KEY, null)?.let { legacy ->
                    listOfNotNull(PairingLink.parse(decrypt(legacy))).also { links ->
                        saveAll(context, links)
                        prefs.edit().remove(LEGACY_KEY).commit()
                    }
                }
                ?: emptyList()
        } catch (e: Exception) {
            Log.w("OpenScribe", "Stored pairings could not be read; pair again", e)
            emptyList()
        }
    }

    fun saveAll(context: Context, links: List<PairingLink>) {
        val prefs = prefs(context).edit()
        if (links.isEmpty()) prefs.remove(KEY) else prefs.putString(KEY, encrypt(links.joinToString("\n") { it.toUri() }))
        prefs.commit()
    }

    @Volatile private var clipKey: ByteArray? = null

    /**
     * The AES-256 key for cached clipboard images (see [ImageClips]), created on first use. It is stored encrypted
     * with the Keystore key and only held in memory here. [fresh] is true when a new key had to be made, so files
     * sealed with an older one can be deleted.
     */
    @Synchronized
    fun clipKey(context: Context): Pair<ByteArray, Boolean> {
        clipKey?.let { return it to false }
        val prefs = prefs(context)
        val existing = try {
            prefs.getString(CLIP_KEY, null)?.let { Base64Url.decode(decrypt(it)) }?.takeIf { it.size == 32 }
        } catch (e: Exception) {
            Log.w("OpenScribe", "Clipboard image key could not be read; making a new one")
            null
        }
        if (existing != null) {
            clipKey = existing
            return existing to false
        }
        val created = LinkProtocol.randomBytes(32)
        prefs.edit().putString(CLIP_KEY, encrypt(Base64Url.encode(created))).commit()
        clipKey = created
        return created to true
    }

    fun activeMacId(context: Context): String? = prefs(context).getString(ACTIVE, null)

    fun setActiveMacId(context: Context, id: String?) {
        prefs(context).edit().apply { if (id == null) remove(ACTIVE) else putString(ACTIVE, id) }.commit()
    }
}
