package io.github.utabako

import android.net.DnsResolver
import android.net.Network
import android.os.CancellationSignal
import android.system.ErrnoException
import libbox.ExchangeContext
import libbox.LocalDNSTransport
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException

internal class AndroidDnsTransport(
    private val defaultNetwork: () -> Network?
) : LocalDNSTransport {
    override fun raw(): Boolean = true

    override fun exchange(context: ExchangeContext, message: ByteArray) {
        val network = checkNotNull(defaultNetwork()) { "No underlying network for system DNS" }
        val signal = CancellationSignal()
        val response = CompletableFuture<Pair<ByteArray, Int>>()
        context.onCancel {
            signal.cancel()
            response.cancel(false)
        }
        DnsResolver.getInstance().rawQuery(
            network,
            message,
            DnsResolver.FLAG_NO_RETRY,
            { it.run() },
            signal,
            object : DnsResolver.Callback<ByteArray> {
                override fun onAnswer(answer: ByteArray, rcode: Int) {
                    response.complete(answer to rcode)
                }

                override fun onError(error: DnsResolver.DnsException) {
                    response.completeExceptionally(error)
                }
            }
        )
        val (answer, rcode) = try {
            response.get()
        } catch (error: ExecutionException) {
            val cause = error.cause
            val errno = (cause as? DnsResolver.DnsException)?.cause as? ErrnoException
            if (errno != null) {
                context.errnoCode(errno.errno)
                return
            }
            throw cause ?: error
        }
        if (rcode == 0) {
            context.rawSuccess(answer)
        } else {
            context.errorCode(rcode)
        }
    }

    override fun lookup(context: ExchangeContext, network: String, domain: String) {
        throw UnsupportedOperationException("System DNS uses raw queries")
    }
}
