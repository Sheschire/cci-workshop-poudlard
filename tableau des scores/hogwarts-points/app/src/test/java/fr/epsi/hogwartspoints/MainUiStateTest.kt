package fr.epsi.hogwartspoints

import org.junit.Assert.assertEquals
import org.junit.Test

class MainUiStateTest {
    @Test
    fun defaultState_hasTenPoints() {
        assertEquals(10, MainUiState().points)
    }

    @Test
    fun emptyState_hasNoHouses() {
        assertEquals(0, MainUiState().houses.size)
    }
}
