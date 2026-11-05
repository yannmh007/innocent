package com.innocent.media.seal

/**
 * The DEKs of the objects this process is opening, by dek_id, and the one
 * call the app's unseal gateway makes per run of segments
 * (docs/MEDIA_ENCRYPTION.md §6).
 *
 * WHY THE DEK STAYS HERE. A grant's DEK reaches the phone wrapped for its
 * Keystore key; it is unwrapped once, on this side of the platform channel,
 * and never crosses back into Dart. Dart holds a dek_id and asks for runs of
 * segments to be opened under it.
 *
 * BOUNDED. A viewer moving through a ladder registers one DEK per rung, a
 * few per film; [LIMIT] is far above any session and keeps a process that
 * plays for days from collecting keys. The oldest is forgotten first — it
 * is registered again by the grant that next needs it.
 *
 * Pure JVM, so tool/sealjvm tests the code the APK carries.
 */
object SealKeyring {
    const val LIMIT = 48

    private val deks = object : LinkedHashMap<String, ByteArray>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ByteArray>): Boolean {
            if (size <= LIMIT) return false
            eldest.value.fill(0)
            openers.keys.removeAll { it.startsWith(eldest.key + "|") }
            return true
        }
    }

    /** Openers by dek_id, header and size: one HKDF per object, not per run. */
    private val openers = HashMap<String, SealOpener>()

    /** Keeps a copy of [dek] for [dekId]; the caller clears its own. */
    @Synchronized
    fun put(dekId: String, dek: ByteArray) {
        if (dekId.isEmpty()) throw SealException("a DEK needs its id")
        if (dek.size != 32) throw SealException("a DEK is 32 bytes, not ${dek.size}")
        val old = deks[dekId]
        if (old != null && old.contentEquals(dek)) return
        // Another DEK under the same id would open nothing it sealed; the
        // openers made with the old one go with it.
        old?.fill(0)
        openers.keys.removeAll { it.startsWith("$dekId|") }
        deks[dekId] = dek.copyOf()
    }

    @Synchronized
    fun has(dekId: String): Boolean = deks.containsKey(dekId)

    @Synchronized
    fun forget(dekId: String) {
        deks.remove(dekId)?.fill(0)
        openers.keys.removeAll { it.startsWith("$dekId|") }
    }

    @Synchronized
    fun size(): Int = deks.size

    /**
     * The plaintext of consecutive segments [first].. of one object, laid end
     * to end in [sealed] as one aligned range request returned them.
     * [header] is the object's first 40 bytes; [plainTotal] its plaintext
     * size. Throws [SealException] for an unknown dek_id and for anything
     * that does not open.
     */
    fun openRun(dekId: String, header: ByteArray, plainTotal: Long, first: Long, sealed: ByteArray): ByteArray {
        val op = opener(dekId, header, plainTotal)
        return op.openRun(first, sealed)
    }

    /**
     * A whole small object — a poster, an album photo — opened with the DEK
     * its catalogue row carried (docs/MEDIA_ENCRYPTION.md §5, photos). The
     * DEK is NOT kept: a grid of posters is a key each, and would push the
     * films' keys out of [LIMIT]. [sealed] is the object as stored, header
     * first. Throws [SealException] for anything that does not open.
     */
    fun openWhole(dekId: String, dek: ByteArray, sealed: ByteArray): ByteArray {
        if (dekId.isEmpty()) throw SealException("a DEK needs its id")
        if (dek.size != 32) throw SealException("a DEK is 32 bytes, not ${dek.size}")
        if (sealed.size < MediaSeal.HEADER + MediaSeal.TAG || sealed.size > WHOLE_LIMIT) {
            throw SealException("not a whole small object: ${sealed.size} bytes")
        }
        val plain = MediaSeal.plainSize(sealed.size.toLong())
        val op = SealOpener(dek, MediaSeal.aadFor(dekId), sealed.copyOf(MediaSeal.HEADER), plain)
        return op.openRun(0, sealed, MediaSeal.HEADER, sealed.size - MediaSeal.HEADER)
    }

    /** The largest object [openWhole] takes in one call: far above a photo. */
    const val WHOLE_LIMIT = 32 * 1024 * 1024

    /** The DEK itself, for wrapping it for this device's storage. */
    @Synchronized
    fun copyOf(dekId: String): ByteArray = deks[dekId]?.copyOf() ?: throw SealException("no DEK for $dekId")

    @Synchronized
    private fun opener(dekId: String, header: ByteArray, plainTotal: Long): SealOpener {
        if (header.size != MediaSeal.HEADER) throw SealException("a header is ${MediaSeal.HEADER} bytes, not ${header.size}")
        val k = dekId + "|" + header.joinToString("") { "%02x".format(it) } + "|" + plainTotal
        openers[k]?.let { return it }
        val dek = deks[dekId] ?: throw SealException("no DEK for $dekId")
        val made = SealOpener(dek, MediaSeal.aadFor(dekId), header, plainTotal)
        // A few per DEK at most (a rung's header does not change); bounded
        // anyway, against a caller that sends a new header every time.
        if (openers.size >= LIMIT * 4) openers.clear()
        openers[k] = made
        return made
    }
}
