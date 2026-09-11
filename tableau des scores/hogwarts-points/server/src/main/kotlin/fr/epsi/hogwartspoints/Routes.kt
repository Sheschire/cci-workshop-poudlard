package fr.epsi.hogwartspoints

import io.ktor.http.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*

fun Route.apiRoutes(repository: AppRepository) {
    route("/api") {
        get("/health") {
            call.respond(mapOf("status" to "ok"))
        }

        get("/houses") {
            call.respond(repository.houses().sortedByDescending { it.points })
        }

        get("/scores") {
            call.respond(repository.scores())
        }

        post("/scores") {
            val request = call.receive<AddScoreRequest>()
            call.respond(HttpStatusCode.Created, repository.add(request))
        }

        delete("/scores/last") {
            call.respond(repository.undoLast())
        }

        post("/scores/reset") {
            repository.reset()
            call.respond(HttpStatusCode.NoContent)
        }
    }
}
