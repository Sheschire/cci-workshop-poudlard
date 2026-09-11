package fr.epsi.hogwartspoints

import io.ktor.client.call.body
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.server.config.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.server.testing.*
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class RoutesTest {
    @Test
    fun `health endpoint returns ok`() = testApplication {
        application {
            install(ContentNegotiation) { json(Json) }
            routingForTest()
        }
        val response = client.get("/api/health")
        assertEquals(HttpStatusCode.OK, response.status)
        assertTrue(response.bodyAsText().contains("ok"))
    }

    @Test
    fun `houses endpoint returns four houses`() = testApplication {
        application {
            install(ContentNegotiation) { json(Json) }
            routingForTest()
        }
        val response = client.get("/api/houses")
        assertEquals(HttpStatusCode.OK, response.status)
        val houses = response.body<List<HouseDto>>()
        assertEquals(4, houses.size)
    }

    @Test
    fun `post score returns created`() = testApplication {
        application {
            install(ContentNegotiation) { json(Json) }
            routingForTest()
        }
        val response = client.post("/api/scores") {
            contentType(ContentType.Application.Json)
            setBody(AddScoreRequest(1, 25, "Test API"))
        }
        assertEquals(HttpStatusCode.Created, response.status)
        assertEquals(25, response.body<ScoreDto>().points)
    }

    @Test
    fun `reset endpoint returns no content`() = testApplication {
        application {
            install(ContentNegotiation) { json(Json) }
            routingForTest()
        }
        client.post("/api/scores") {
            contentType(ContentType.Application.Json)
            setBody(AddScoreRequest(1, 25, "Test"))
        }
        val response = client.post("/api/scores/reset")
        assertEquals(HttpStatusCode.NoContent, response.status)
    }

    private fun ApplicationTestBuilder.routingForTest() {
        val db = DatabaseFactory.forTest(
            "jdbc:h2:mem:routesdb${System.nanoTime()};MODE=PostgreSQL;DB_CLOSE_DELAY=-1"
        )
        val repository = AppRepository(db)
        routing { apiRoutes(repository) }
    }
}
