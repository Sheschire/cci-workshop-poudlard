package fr.epsi.hogwartspoints.network

import fr.epsi.hogwartspoints.BuildConfig
import fr.epsi.hogwartspoints.model.AddScoreRequest
import fr.epsi.hogwartspoints.model.House
import fr.epsi.hogwartspoints.model.ScoreEntry
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.engine.android.Android
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.serialization.json.Json

class ApiClient(
    private val client: HttpClient = HttpClient(Android) {
        install(ContentNegotiation) {
            json(Json { ignoreUnknownKeys = true })
        }
    },
    private val baseUrl: String = BuildConfig.API_BASE_URL
) {
    suspend fun getHouses(): List<House> =
        client.get("${baseUrl}api/houses").body()

    suspend fun getScores(): List<ScoreEntry> =
        client.get("${baseUrl}api/scores").body()

    suspend fun addScore(request: AddScoreRequest): ScoreEntry =
        client.post("${baseUrl}api/scores") {
            contentType(ContentType.Application.Json)
            setBody(request)
        }.body()

    suspend fun undoLast(): ScoreEntry =
        client.delete("${baseUrl}api/scores/last").body()

    suspend fun reset(): Unit {
        client.post("${baseUrl}api/scores/reset")
    }
}
