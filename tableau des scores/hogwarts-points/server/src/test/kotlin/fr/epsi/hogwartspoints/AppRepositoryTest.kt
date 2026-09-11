package fr.epsi.hogwartspoints

import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AppRepositoryTest {
    private lateinit var repository: AppRepository

    @BeforeEach
    fun setUp() {
        repository = AppRepository(
            DatabaseFactory.forTest(
                "jdbc:h2:mem:testdb;MODE=PostgreSQL;DB_CLOSE_DELAY=-1"
            )
        )
        repository.reset()
    }

    @Test
    fun `four houses exist`() {
        assertEquals(4, repository.houses().size)
    }

    @Test
    fun `new score changes house ranking`() {
        repository.add(AddScoreRequest(1, 50, "Victoire"))
        val gryffondor = repository.houses().first { it.id == 1L }
        assertEquals(50, gryffondor.points)
        assertEquals("Gryffondor", repository.houses().maxBy { it.points }.name)
    }

    @Test
    fun `negative score is supported`() {
        repository.add(AddScoreRequest(2, -10, "Infraction"))
        assertEquals(-10, repository.houses().first { it.id == 2L }.points)
    }

    @Test
    fun `zero score is rejected`() {
        assertThrows<IllegalArgumentException> {
            repository.add(AddScoreRequest(1, 0, "Test"))
        }
    }

    @Test
    fun `out of range score is rejected`() {
        assertThrows<IllegalArgumentException> {
            repository.add(AddScoreRequest(1, 101, "Test"))
        }
    }

    @Test
    fun `blank reason is rejected`() {
        assertThrows<IllegalArgumentException> {
            repository.add(AddScoreRequest(1, 10, " "))
        }
    }

    @Test
    fun `unknown house is rejected`() {
        assertThrows<IllegalArgumentException> {
            repository.add(AddScoreRequest(999, 10, "Test"))
        }
    }

    @Test
    fun `history contains created score`() {
        repository.add(AddScoreRequest(3, 20, "Entraide"))
        val history = repository.scores()
        assertEquals(1, history.size)
        assertEquals("Poufsouffle", history.first().houseName)
    }

    @Test
    fun `undo removes latest score`() {
        repository.add(AddScoreRequest(1, 20, "A"))
        repository.add(AddScoreRequest(2, 30, "B"))
        val removed = repository.undoLast()
        assertEquals(30, removed.points)
        assertEquals(20, repository.houses().first { it.id == 1L }.points)
        assertEquals(0, repository.houses().first { it.id == 2L }.points)
    }

    @Test
    fun `undo without history is rejected`() {
        assertThrows<IllegalStateException> { repository.undoLast() }
    }

    @Test
    fun `reset clears all scores`() {
        repository.add(AddScoreRequest(1, 20, "A"))
        repository.add(AddScoreRequest(2, 10, "B"))
        repository.reset()
        assertTrue(repository.scores().isEmpty())
        assertTrue(repository.houses().all { it.points == 0 })
    }

    @Test
    fun `reason is trimmed`() {
        val score = repository.add(AddScoreRequest(4, 15, "  Sagesse  "))
        assertEquals("Sagesse", score.reason)
    }

    @Test
    fun `long reason is rejected`() {
        assertThrows<IllegalArgumentException> {
            repository.add(AddScoreRequest(1, 10, "x".repeat(121)))
        }
    }
}
