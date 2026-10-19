package chat.xucheri.androidonmac.receiver

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class SavedPair(val endpoint: Bootstrap, val authToken: String)

/** Secrets stay in app-private storage, encrypted with a non-exportable Android Keystore key. */
class PairStore(context: Context) {
    private val preferences = context.getSharedPreferences("receiver_identity", Context.MODE_PRIVATE)
    val deviceID: String = preferences.getString("deviceID", null) ?: UUID.randomUUID().toString().also {
        preferences.edit().putString("deviceID", it).commit()
    }
    @Synchronized private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    @Synchronized fun load(): SavedPair? {
        val encoded = preferences.getString("paired", null) ?: return null
        return try {
            val sealed = Base64.decode(encoded, Base64.NO_WRAP)
            if (sealed.size < 29) return null
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed.copyOfRange(0, 12)))
            cipher.updateAAD(ALIAS.toByteArray())
            val json = JSONObject(cipher.doFinal(sealed.copyOfRange(12, sealed.size)).toString(Charsets.UTF_8))
            val endpoint = Bootstrap.parse(json.getJSONObject("endpoint").toString())
            SavedPair(endpoint.withoutToken(), json.getString("authToken"))
        } catch (_: Exception) { null }
    }
    @Synchronized fun save(endpoint: Bootstrap, token: String) {
        require(token.length in 16..4096)
        val json = JSONObject().put("endpoint", JSONObject().put("v", 1).put("host", endpoint.host)
            .put("port", endpoint.port).put("fingerprint", endpoint.fingerprint)).put("authToken", token)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key()); cipher.updateAAD(ALIAS.toByteArray())
        val sealed = cipher.iv + cipher.doFinal(json.toString().toByteArray(Charsets.UTF_8))
        if (!preferences.edit().putString("paired", Base64.encodeToString(sealed, Base64.NO_WRAP)).commit())
            throw IllegalStateException("无法安全保存配对，请检查手机存储空间")
    }
    fun forget() { preferences.edit().remove("paired").apply() }
    companion object { private const val ALIAS = "androidonmac.receiver.pair.v1" }
}
