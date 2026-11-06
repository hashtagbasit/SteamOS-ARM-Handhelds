package org.zaviya.installer.root

/** What a root job last reported in its status file. */
data class JobStatus(
    val state: String,
    val done: Long,
    val total: Long,
    val message: String,
    val values: Map<String, String>,
) {
    val finished get() = state == "done" || state == "failed"
    val fraction get() = if (total > 0) (done.toDouble() / total).coerceIn(0.0, 1.0).toFloat() else 0f

    companion object {
        /** Parses key=value lines; null when the file belongs to another job. */
        fun parse(text: String, jobId: String): JobStatus? {
            val v = text.lineSequence().mapNotNull { l -> l.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }.toMap()
            if (v["job"] != jobId) return null
            return JobStatus(v["state"].orEmpty(), v["done"]?.toLongOrNull() ?: 0, v["total"]?.toLongOrNull() ?: 0, v["message"].orEmpty(), v)
        }
    }
}
