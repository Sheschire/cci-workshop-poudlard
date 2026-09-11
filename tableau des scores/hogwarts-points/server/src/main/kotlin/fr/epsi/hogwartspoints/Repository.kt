package fr.epsi.hogwartspoints

import org.jetbrains.exposed.sql.*
import org.jetbrains.exposed.sql.transactions.transaction
import java.time.Instant

class AppRepository(private val database: DatabaseFactory) {
    init { database.init() }

    fun houses(): List<HouseDto> = transaction {
        val totals = Scores
            .slice(Scores.houseId, Scores.points.sum())
            .selectAll()
            .groupBy(Scores.houseId)
            .associate { it[Scores.houseId] to (it[Scores.points.sum()] ?: 0) }

        Houses.selectAll().map {
            HouseDto(
                id = it[Houses.id],
                name = it[Houses.name],
                points = totals[it[Houses.id]] ?: 0,
                color = it[Houses.color]
            )
        }
    }

    fun scores(): List<ScoreDto> = transaction {
        (Scores innerJoin Houses)
            .selectAll()
            .orderBy(Scores.createdAt, SortOrder.DESC)
            .map { toDto(it) }
    }

    fun add(request: AddScoreRequest): ScoreDto = transaction {
        require(request.points in -100..100 && request.points != 0) {
            "Les points doivent être compris entre -100 et 100 et différents de 0."
        }
        require(request.reason.isNotBlank()) { "Le motif est obligatoire." }
        require(request.reason.length <= 120) { "Le motif est trop long." }
        require(Houses.select(Houses.id).where { Houses.id eq request.houseId }.count() == 1L) {
            "Maison inconnue."
        }

        val id = Scores.insertAndGetId {
            it[houseId] = request.houseId
            it[points] = request.points
            it[reason] = request.reason.trim()
            it[createdAt] = Instant.now().toEpochMilli()
        }.value

        (Scores innerJoin Houses).selectAll().where { Scores.id eq id }.single().let(::toDto)
    }

    fun undoLast(): ScoreDto = transaction {
        val last = Scores.selectAll().orderBy(Scores.createdAt, SortOrder.DESC).limit(1).firstOrNull()
            ?: throw IllegalStateException("Aucune action à annuler.")
        val dto = (Scores innerJoin Houses).selectAll().where { Scores.id eq last[Scores.id] }.single().let(::toDto)
        Scores.deleteWhere { Scores.id eq last[Scores.id] }
        dto
    }

    fun reset() = transaction { Scores.deleteAll() }

    private fun toDto(row: ResultRow): ScoreDto =
        ScoreDto(
            id = row[Scores.id],
            houseId = row[Scores.houseId],
            houseName = row[Houses.name],
            points = row[Scores.points],
            reason = row[Scores.reason],
            createdAt = Instant.ofEpochMilli(row[Scores.createdAt]).toString()
        )
}
