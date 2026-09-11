package fr.epsi.hogwartspoints.model

import kotlinx.serialization.Serializable

@Serializable
data class House(
    val id: Long,
    val name: String,
    val points: Int,
    val color: String
)

@Serializable
data class ScoreEntry(
    val id: Long,
    val houseId: Long,
    val houseName: String,
    val points: Int,
    val reason: String,
    val createdAt: String
)

@Serializable
data class AddScoreRequest(
    val houseId: Long,
    val points: Int,
    val reason: String
)
