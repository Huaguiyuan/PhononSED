!-------------------------------------------------------------------------------------
! eigvec_projection
!-------------------------------------------------------------------------------------
! Copyright (c) 2017 Daniel C. Elton
!
! This software is licensed under The MIT License (MIT)
! Permission is hereby granted, free of charge, to any person obtaining a copy of this
! software and associated documentation files (the "Software"), to deal in the Software
! without restriction, including without limitation the rights to use, copy, modify, merge,
! publish, distribute, sublicense, and/or sell copies of the Software, and to permit
! persons to whom the Software is furnished to do so, subject to the following conditions:
!
! The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
!
! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
! BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
! NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
! DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
!-------------------------------------------------------------------------------------
module eig_project
    use main_vars
    implicit none

 contains

!-----------------------------------------------------------------------
!----------------- project velocities onto eigenvector k --------------
!-----------------------------------------------------------------------
subroutine calculate_frequencies_and_smoothing
 implicit none
 integer :: PointsAvailable
 real(8) :: MaxFreqPossible

 length = Ntimesteps

 allocate(spectrum_freqs(Ntimesteps))

 do i = 1, Ntimesteps
   spectrum_freqs(i) = dble(i)/(timestep*length)
 enddo

 spectrum_freqs = spectrum_freqs/(ps2s*Cspeed) !convert to 1/cm

 allocate(freqs_smoothed(NPointsOut))

 BlockSize = floor(real(length/NPointsOut))

 do i = 1, NPointsOut
    freqs_smoothed(i) = sum(spectrum_freqs((i-1)*BlockSize+1:i*BlockSize) ) /BlockSize
 enddo

 !------------ figure out variables for smoothing --------------
 MinFreqOut =  spectrum_freqs(2) !smallest possible frequency
 MaxFreqPossible = spectrum_freqs(Ntimesteps) !largest frequency

 if (MaxFreqOut .gt. MaxFreqPossible) MaxFreqOut = MaxFreqPossible

 PointsAvailable = floor(MaxFreqOut/MinFreqOut) !max number possible

 if (PointsAvailable .lt. NPointsOut) NPointsOut = PointsAvailable

 BlockSize = floor(real(Length)/real(NPointsOut))

 allocate(all_SED_smoothed(Nk, Neig, NPointsOut))

 if (BTEMD) allocate(all_corr_fns(Nk, Neig, Ncorrptsout))

end subroutine calculate_frequencies_and_smoothing


!-----------------------------------------------------------------------
!----------------- project velocities onto eigenvector k --------------
!-----------------------------------------------------------------------
subroutine eigen_projection_and_SED(eig, SED_smoothed, ik)
 implicit none
 integer, intent(in) :: ik
 real(8), dimension(Natoms, 3), intent(in) :: eig !!Eigenvector to project onto
 real(8), dimension(NpointsOut), intent(out) :: SED_smoothed
 real(8), dimension(Ntimesteps) :: SED
 real(8) :: part1


 !-------- projection
 do t = 1, Ntimesteps
     qdot(t) = 0
     do ia = 1, Natoms
         part1 = MassPrefac(ia)*dot_product(velocities(t, ia, :), eig(ia, :))
         qdot(t) = qdot(t) + part1*exp(  dcmplx(0, 1)*dot_product(k_vectors(ik, :), r_eq(ia, :))  )
     enddo
 enddo

!--------- calculate Spectral Energy Density
 call calc_DFT_squared(qdot, SED, length)

 SED = (1d0/3.14159d0)*SED/timestep !!*(1d0/(2*length) ) division performed in DFT routine

 !------- block averaging / smoothing
 do i = 1, NPointsOut
   SED_smoothed(i) = sum(SED((i-1)*BlockSize+1:i*BlockSize) ) /BlockSize
 enddo

end subroutine eigen_projection_and_SED




!------------------------------------------------------------------------------
!- "BTE_MD" method (time domain method from energy-energy correlation fun.) --
!------------------------------------------------------------------------------
subroutine BTE_MD(eig, SED_smoothed, ik, ie, BTEMD_corr_fun_out)
 implicit none
 integer, intent(in) :: ik, ie
 real(8), dimension(Natoms, 3), intent(in) :: eig !!Eigenvector to project onto
 real(8), dimension(NpointsOut), intent(out) :: SED_smoothed
 real(8), dimension(Ncorrptsout), intent(out) :: BTEMD_corr_fun_out
 real(8), dimension(Ntimesteps) :: Ekw, SED,  BTEMD_corr_fun
 double complex :: exppart, q1, qdot

 !-------- projection
 do t = 1, Ntimesteps
     qdot =  dcmplx(0, 0)
     q1 =  dcmplx(0, 0)
     do ia = 1, Natoms
         exppart = exp(  dcmplx(0, -1)*dot_product(k_vectors(ik, :), r_eq(ia, :))  )

         qdot = qdot + MassPrefac(ia)*dot_product(velocities(t, ia, :), eig(ia, :))*exppart

         q1 = q1 +  MassPrefac(ia)*dot_product(coordinates(t, ia, :) -  r_eq(ia, :), eig(ia, :))*exppart
     enddo
     Ekw(t) = (freqs(ik, ie)**2)*q1*conjg(q1)/2d0 + qdot*conjg(qdot)/2d0
 enddo

 !--------- calculate correlation function
 call calc_corr_function2(Ekw, BTEMD_corr_fun, Ntimesteps)

 BTEMD_corr_fun_out = BTEMD_corr_fun(1:Ncorrptsout)/BTEMD_corr_fun(1)

 !--------- calculate Spectral Energy Density for the mode
 call calc_DFT(BTEMD_corr_fun, SED, Ntimesteps)

 SED = (1d0/3.14159d0)*SED/timestep !!*(1d0/(2*length) ) division performed in DFT routine

 !------- block averaging / smoothing
 do i = 1, NPointsOut
   SED_smoothed(i) = sum(SED((i-1)*BlockSize+1:i*BlockSize) ) /BlockSize
 enddo

end subroutine BTE_MD


!------------------------------------------------------------------------
!-------  Compute DFT squared (discrete Fourier transform) using four1.f
!------------------------------------------------------------------------
subroutine calc_DFT_squared(input, output, tread)
 Implicit none
 integer, intent(in) :: tread
 double complex, dimension(tread), intent(in) :: input
 double precision, dimension(tread), intent(out) ::  output
 complex, dimension(:), allocatable :: transformed
 integer :: trun

 !zero padding
 trun = 2**(    floor( dlog(  dble(tread)  )/dlog(2d0)  )  + 1 )

 if (.not. allocated(transformed)) then
 	allocate(transformed(0:2*trun-1))
 elseif (.not. (2*trun .eq. size(transformed))) then
	deallocate(transformed)
	allocate(transformed(0:2*trun-1))
 endif

 transformed = 0
 transformed(0:tread-1) = input

 call four1(transformed,2*trun,1)

 output=dble(transformed(0:tread-1)*CONJG(transformed(0:tread-1)))/(2d0*trun)

end subroutine calc_DFT_squared

!------------------------------------------------------------------------
!----------------  Compute AUTOcorrelation function using four1.f-------
!------------------------------------------------------------------------
subroutine calc_corr_function2(input,output,N)
 Implicit none
 double precision, dimension(N), intent(in) :: input
 real(8), dimension(N), intent(out) :: output
 integer, intent(in) :: N
 double complex, dimension(:), allocatable :: input_padded,  output_padded
 complex, dimension(:), allocatable :: transformed
 integer*8 :: plan=0, i, trun

 if (.not.(allocated(input_padded))) then
 	!find closest power of 2 greater than number of steps
 	trun = 2**(    floor( dlog(  dble(N) )/dlog(2d0)  )  + 1  )
	allocate(input_padded(2*trun))
	allocate(output_padded(2*trun))
	allocate(transformed(2*trun))
 endif

 input_padded = 0
 input_padded(1:N) = cmplx(input)

 transformed = real(input_padded)

 call four1(transformed,2*trun,1)

 transformed = transformed*conjg(transformed)

 call four1(transformed,2*trun,-1)

 output = dble(transformed(1:N))/N

 !normalization 1
 do i = 1, N-1
	output(i) = output(i)/(N-i)
 enddo

end subroutine calc_corr_function2

!------------------------------------------------------------------------
!-------  Compute DFT (discrete Fourier transform) using four1.f
!------------------------------------------------------------------------
subroutine calc_DFT(input, output, tread)
 Implicit none
 integer, intent(in) :: tread
 double precision, dimension(tread), intent(in) :: input
 double precision, dimension(tread), intent(out) ::  output
 complex, dimension(:), allocatable :: transformed
 integer :: trun

 !zero padding
 trun = 2**(    floor( dlog(  dble(tread)  )/dlog(2d0)  )  + 1 )

 if (.not. allocated(transformed)) then
 	allocate(transformed(0:2*trun-1))
 elseif (.not. (2*trun .eq. size(transformed))) then
	deallocate(transformed)
	allocate(transformed(0:2*trun-1))
 endif

 transformed = 0
 transformed(0:tread-1) = cmplx(input)

 call four1(transformed,2*trun,1)

 output=dble(transformed(0:tread-1))/(2d0*trun)

end subroutine calc_DFT

end module eig_project
