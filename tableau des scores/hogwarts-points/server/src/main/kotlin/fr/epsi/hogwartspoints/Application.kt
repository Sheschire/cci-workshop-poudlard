package fr.epsi.hogwartspoints

import io.ktor.serialization.kotlinx.json.*
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.calllogging.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.server.plugins.statuspages.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.serialization.json.Json

fun main() {
    embeddedServer(Netty, port = System.getenv("PORT")?.toIntOrNull() ?: 8080, host = "0.0.0.0") {
        module()
    }.start(wait = true)
}

fun Application.module() {
    install(CallLogging)
    install(ContentNegotiation) {
        json(Json { prettyPrint = true; ignoreUnknownKeys = true })
    }
    install(StatusPages) {
        exception<IllegalArgumentException> { call, cause ->
            call.respond(io.ktor.http.HttpStatusCode.BadRequest, ErrorResponse(cause.message ?: "Requête invalide"))
        }
        exception<Throwable> { call, _ ->
            call.respond(io.ktor.http.HttpStatusCode.InternalServerError, ErrorResponse("Erreur interne"))
        }
    }

    val repository = AppRepository(DatabaseFactory.fromEnvironment())
    routing {
        apiRoutes(repository)
        swaggerUI(path = "swagger", swaggerFile = "openapi/documentation.yaml")
    }
}
